$runtimeIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$root = (Resolve-Path ".").Path
$stateDir = Join-Path $root ".ui-verification"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$stdout = Join-Path $stateDir "dev-server.out.log"
$stderr = Join-Path $stateDir "dev-server.err.log"
$pidFile = Join-Path $stateDir "dev-server.pid.json"
$url = "http://127.0.0.1:5173/"
$serverScript = "node_modules/vite/bin/vite.js"
$nodeCommandName = if ($runtimeIsWindows) { "node.exe" } else { "node" }
$serverEntry = (Get-Command $nodeCommandName -CommandType Application -ErrorAction Stop).Source
$serverArguments = @(
  $serverScript,
  "--host", "127.0.0.1",
  "--port", "5173",
  "--strictPort"
)

if (-not (Test-Path -LiteralPath (Join-Path $root $serverScript) -PathType Leaf)) {
  throw "The direct Vite server entry was not found."
}

$verifyUi = {
  throw "Replace the verifyUi placeholder with bounded browser verification."
}

$server = $null
$serverHandle = $null
$serverStartTimeUtc = $null
$verificationFailure = $null
$cleanupFailure = $null
$cleanupStageFailures = [System.Collections.Generic.List[System.Exception]]::new()
$cleanupResult = "Server process was not started."

try {
  $startParameters = @{
    FilePath = $serverEntry
    ArgumentList = $serverArguments
    WorkingDirectory = $root
    RedirectStandardOutput = $stdout
    RedirectStandardError = $stderr
    PassThru = $true
  }
  if ($runtimeIsWindows) {
    $startParameters["WindowStyle"] = "Hidden"
  }

  $server = Start-Process @startParameters

  # Force the Process object to acquire its OS handle immediately. Cleanup keeps
  # this same handle and never re-resolves the PID, so PID reuse cannot retarget it.
  $serverHandle = $server.SafeHandle
  if ($null -eq $serverHandle -or
    $serverHandle.IsInvalid -or
    $serverHandle.IsClosed) {
    throw "The direct server process handle could not be retained."
  }

  # PID and start time are report evidence only; cleanup identity comes from
  # the retained handle above.
  $serverStartTimeUtc = $server.StartTime.ToUniversalTime()
  [ordered]@{
    pid = $server.Id
    startTimeUtc = $serverStartTimeUtc.ToString("O")
  } |
    ConvertTo-Json -Compress |
    Set-Content -LiteralPath $pidFile -Encoding UTF8

  $ready = $false
  for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
      $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        $ready = $true
        break
      }
    } catch {
      if ($attempt -lt 30) {
        Start-Sleep -Seconds 1
      }
    }
  }

  if (-not $ready) {
    $stderrSizeBytes = 0
    if (Test-Path -LiteralPath $stderr -PathType Leaf) {
      $stderrSizeBytes = (Get-Item -LiteralPath $stderr).Length
    }
    $healthDiagnostic = [pscustomobject][ordered]@{
      classification = "readiness-timeout"
      logId = "dev-server.err.log"
      logBytes = $stderrSizeBytes
      attempts = 30
    }
    Write-Warning ($healthDiagnostic | ConvertTo-Json -Compress)
    throw [System.TimeoutException]::new(
      "Server readiness timed out; inspect the classified log metadata."
    )
  }

  # Replace this fail-closed script block with route/state-specific browser
  # checks whose navigation and readiness waits are also finite.
  & $verifyUi
}
catch {
  $verificationFailure = $_.Exception
}
finally {
  if ($null -ne $server) {
    try {
      # SafeHandle acquisition can fail after Start-Process has already returned.
      # Keep cleaning the directly returned Process object so partial start cannot
      # bypass bounded shutdown; the PID is still never re-resolved.
      if ($null -eq $serverHandle -or
        $serverHandle.IsInvalid -or
        $serverHandle.IsClosed) {
        $cleanupResult = "Partial-start cleanup is using the direct Process object."
      }
      if ($server.HasExited) {
        $cleanupResult = "Server process had already stopped."
      } else {
        try {
          $server.Kill()
        } catch {
          # Windows PowerShell 5.1 can observe HasExited=false and then lose the
          # race to a natural exit before Kill. Recheck only this retained object.
          if (-not $server.HasExited) {
            throw
          }
        }
        if (-not $server.HasExited) {
          if (-not $server.WaitForExit(5000)) {
            throw [System.TimeoutException]::new(
              "Server process did not stop within the bounded cleanup wait."
            )
          }
        }
        $cleanupResult = "Server process stop was confirmed."
      }
    } catch {
      $cleanupStageFailures.Add($_.Exception) | Out-Null
    } finally {
      # Each disposal has its own catch so a later failure cannot hide an earlier
      # stop or SafeHandle failure. Nested finally still guarantees Process.Dispose.
      try {
        if ($null -ne $serverHandle) {
          try {
            $serverHandle.Dispose()
          } catch {
            $cleanupStageFailures.Add($_.Exception) | Out-Null
          }
        }
      } finally {
        try {
          $server.Dispose()
        } catch {
          $cleanupStageFailures.Add($_.Exception) | Out-Null
        }
      }
    }
    if ($cleanupStageFailures.Count -eq 1) {
      $cleanupFailure = $cleanupStageFailures[0]
    } elseif ($cleanupStageFailures.Count -gt 1) {
      $cleanupFailure = [System.AggregateException]::new(
        "Multiple server cleanup stages failed.",
        $cleanupStageFailures
      )
    }
    if ($cleanupStageFailures.Count -gt 0) {
      $cleanupResult = "Cleanup failed; inspect the propagated exception."
    }
  }
}

if ($null -ne $verificationFailure -and $null -ne $cleanupFailure) {
  $failures = [System.Collections.Generic.List[System.Exception]]::new()
  $failures.Add($verificationFailure)
  $failures.Add($cleanupFailure)
  throw [System.AggregateException]::new(
    "Browser verification and server cleanup both failed.",
    $failures
  )
}
if ($null -ne $verificationFailure) {
  throw $verificationFailure
}
if ($null -ne $cleanupFailure) {
  throw $cleanupFailure
}

Write-Host $cleanupResult
