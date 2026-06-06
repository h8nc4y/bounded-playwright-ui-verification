# Bounded Server Runbook

This is a synthetic PowerShell pattern for local UI verification. Adapt the command,
port, and health endpoint to the project.

## Start In Background

```powershell
$root = Resolve-Path "."
$stateDir = Join-Path $root ".ui-verification"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$stdout = Join-Path $stateDir "dev-server.out.log"
$stderr = Join-Path $stateDir "dev-server.err.log"
$pidFile = Join-Path $stateDir "dev-server.pid"

$server = Start-Process -FilePath "npm" `
  -ArgumentList @("run", "dev", "--", "--host", "127.0.0.1") `
  -WorkingDirectory $root `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError $stderr `
  -PassThru `
  -WindowStyle Hidden

Set-Content -LiteralPath $pidFile -Value $server.Id
```

## Bounded Health Check

```powershell
$url = "http://127.0.0.1:5173/"
$ready = $false

for ($attempt = 1; $attempt -le 30; $attempt++) {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
      $ready = $true
      break
    }
  } catch {
    Start-Sleep -Seconds 1
  }
}

if (-not $ready) {
  Get-Content -LiteralPath $stderr -Tail 80
  Stop-Process -Id (Get-Content -LiteralPath $pidFile) -ErrorAction SilentlyContinue
  throw "Server did not become ready within bounded health check attempts."
}
```

## Verify And Cleanup

Run browser verification only after the bounded health check succeeds. After the UI
checks finish:

```powershell
if (Test-Path -LiteralPath $pidFile) {
  $serverId = Get-Content -LiteralPath $pidFile
  Stop-Process -Id $serverId -ErrorAction SilentlyContinue
}
```

Report the PID, log paths, health check result, browser tool, viewport sizes, findings,
and cleanup result. If cleanup fails, report the exact failure instead of assuming the
server stopped.
