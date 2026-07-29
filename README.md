# bounded-playwright-ui-verification

[![CI](https://github.com/h8nc4y/bounded-playwright-ui-verification/actions/workflows/ci.yml/badge.svg)](https://github.com/h8nc4y/bounded-playwright-ui-verification/actions/workflows/ci.yml)

`bounded-playwright-ui-verification` is a Codex-style skill for AI coding agents
that need real browser evidence for Web UI changes while keeping local server
workflows bounded and cleanup explicit.

The skill is about operational discipline. It does not vendor Playwright,
browser binaries, screenshots, icons, or third-party media.

## Who It Is For

- AI coding agents working on React, Next.js, Vite, dashboard, form, or admin UI.
- Agents that can use Playwright, Chrome DevTools, an in-app browser, or another
  browser automation tool.
- Teams that want final reports to distinguish completed browser checks from
  `未確認` items.

## What It Solves

Browser automation capability is widely available; reporting discipline is not.
This skill is a pre-claim evidence contract: it defines when an agent may claim
that browser verification happened, independent of which tool performed the
verification (Playwright scripts, MCP browser tools, or an in-app browser).
Capability layers such as Playwright MCP or Chrome DevTools MCP are
complementary: they provide observation, while this skill constrains what may
be claimed from those observations.

The contract has three parts:

- Bounded execution: every server start, health check, browser wait, and
  cleanup step has a finite timeout, a retry limit, and a cleanup path that
  runs on success, failure, and timeout.
- Truthful reporting: verification categories that were not performed are
  reported as `未確認`, never as passed.
- Evidence separation: verification categories do not imply each other. A green
  build is not UI verification, a DOM node is not a rendered chart, and a hover
  check is not a focus check.

Typical failure modes this contract targets:

- Foreground `npm run dev`, Vite, Next.js, or similar servers blocking an agent
  turn.
- Unbounded waits, infinite polling, and forgotten cleanup.
- UI signoff based only on compile, lint, typecheck, or build output.
- Reports that claim screenshots, console checks, network checks, or responsive
  checks that were not actually performed.
- Missing evidence for 390 px, 768 px, and 1280 px-plus viewport checks.

The skill is a reporting contract, not an enforcement engine. It does not
prevent a determined over-claim by itself; it makes over-claiming explicit and
easier to detect by requiring `未確認` as a first-class reporting term.

## Install

Clone the repository:

```powershell
git clone https://github.com/h8nc4y/bounded-playwright-ui-verification.git
cd bounded-playwright-ui-verification
```

Run the repository checks (see [Validation And Scan](#validation-and-scan))
before copying the skill.

`runtime-files.txt` is the deterministic runtime closure: `SKILL.md` plus the
11 ordered paths in the existing public-example manifest. The same manifest
already fixes the label, path, count, and publication section in both `SKILL.md`
and this README. The required-file gate verifies that every declaration is a
present leaf. Every manifest component must also be portable to Windows (no
reserved device names, alternate data streams, wildcards, control characters,
or trailing dots/spaces).

The supported `SKILL.md` link surface is deliberately small: one exact official
Playwright link followed by the 11 exact single-line public-example links.
Unknown raw `](` lines, reference-style `]:` syntax, and raw HTML `<a>` / `<img>`
link surfaces are unsupported and fail closed. Adding another runtime file is a
reviewed public-manifest change, not automatic CommonMark link discovery.

The repository check does not claim to parse arbitrary Markdown containers.
Instead, it compares this complete `## Install` section through the fixed
`## Manual Use` boundary with canonical text using ordinal equality. Alternate
Install headings, runtime markers, and runtime copy/claim tokens outside this
canonical block are unsupported lexical surfaces, including when they appear in
code or comments. The canonical PowerShell block is also parsed with the
PowerShell AST parser before acceptance.

Manual install into a Codex-style skill directory:

```powershell
# runtime-closure-install:start
$repoRoot = (Resolve-Path ".").Path
$manifestPath = Join-Path $repoRoot "runtime-files.txt"
$runtimeFiles = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
if ($runtimeFiles.Count -ne 12) {
  throw "Runtime manifest must contain exactly 12 files."
}
$runtimeFilesUnique = @($runtimeFiles | Sort-Object -Unique)
if ($runtimeFilesUnique.Count -ne $runtimeFiles.Count) {
  throw "Runtime manifest contains a duplicate path."
}
$assertPortableRuntimePath = {
  param([string]$CandidatePath)

  if ([string]::IsNullOrWhiteSpace($CandidatePath) -or
    $CandidatePath -cne $CandidatePath.Trim() -or
    [IO.Path]::IsPathRooted($CandidatePath) -or
    $CandidatePath.Contains("\")) {
    throw "Runtime manifest contains an unsafe path."
  }
  foreach ($candidateSegment in @($CandidatePath -split "/")) {
    if ([string]::IsNullOrWhiteSpace($candidateSegment) -or
      $candidateSegment -in @(".", "..") -or
      $candidateSegment -match '[\x00-\x1F<>:"\\|?*]' -or
      $candidateSegment -match '[. ]$' -or
      $candidateSegment -match '^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]) *(?:\..*)?$') {
      throw "Runtime manifest contains an unsafe path."
    }
  }
}

$getRequiredFileSha256 = {
  param([string]$LiteralPath)

  # hash取得失敗をnull同士の一致として扱わず、必ず例外でfail closedにする。
  $hashResults = @(
    Microsoft.PowerShell.Utility\Get-FileHash `
      -LiteralPath $LiteralPath `
      -Algorithm SHA256 `
      -ErrorAction Stop
  )
  if ($hashResults.Count -ne 1) {
    throw "SHA-256 calculation did not return exactly one result."
  }
  $hash = [string]$hashResults[0].Hash
  if ($hash -cnotmatch '^[0-9A-F]{64}$') {
    throw "SHA-256 calculation returned an invalid digest."
  }
  return $hash
}

$skillRoot = if ($env:CODEX_HOME) {
  Join-Path $env:CODEX_HOME "skills"
} else {
  Join-Path (Join-Path $HOME ".codex") "skills"
}
$skillRootFullPath = [IO.Path]::GetFullPath($skillRoot)
if (-not (Test-Path -LiteralPath $skillRootFullPath -PathType Container)) {
  throw "Skill root does not exist: $skillRootFullPath"
}
$targetFullPath = [IO.Path]::GetFullPath(
  (Join-Path $skillRootFullPath "bounded-playwright-ui-verification")
)
if (Test-Path -LiteralPath $targetFullPath) {
  throw "Skill already exists: $targetFullPath"
}
$repoItem = Get-Item -LiteralPath $repoRoot -ErrorAction Stop
if ($repoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
  throw "Repository root must not be a reparse point."
}

$repoBoundary = $repoRoot.TrimEnd([char]47, [char]92) +
  [IO.Path]::DirectorySeparatorChar
$stagingName = ".bounded-playwright-ui-verification.install-" +
  [guid]::NewGuid().ToString("N")
$stagingFullPath = [IO.Path]::GetFullPath(
  (Join-Path $skillRootFullPath $stagingName)
)
$stagingBoundary = $stagingFullPath.TrimEnd([char]47, [char]92) +
  [IO.Path]::DirectorySeparatorChar
$copyPlan = foreach ($relativePath in $runtimeFiles) {
  & $assertPortableRuntimePath $relativePath
  $segments = @($relativePath -split "/")

  $sourcePath = [IO.Path]::GetFullPath((Join-Path $repoRoot $relativePath))
  $destinationPath = [IO.Path]::GetFullPath(
    (Join-Path $stagingFullPath $relativePath)
  )
  if (-not $sourcePath.StartsWith(
      $repoBoundary,
      [StringComparison]::OrdinalIgnoreCase
    ) -or
    -not $destinationPath.StartsWith(
      $stagingBoundary,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Runtime manifest path escaped its allowed root."
  }

  $sourceCursor = $repoRoot
  foreach ($segment in $segments) {
    $sourceCursor = Join-Path $sourceCursor $segment
    $sourceItem = Get-Item -LiteralPath $sourceCursor -ErrorAction Stop
    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Runtime manifest path contains a reparse point."
    }
  }
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Runtime manifest source is not a file."
  }

  [pscustomobject]@{
    Source = $sourcePath
    Destination = $destinationPath
    Segments = $segments
    ExpectedHash = & $getRequiredFileSha256 $sourcePath
  }
}

try {
  New-Item `
    -ItemType Directory `
    -Path $stagingFullPath `
    -ErrorAction Stop | Out-Null
  foreach ($copyItem in $copyPlan) {
    $destinationDirectory = Split-Path -Parent $copyItem.Destination
    New-Item `
      -ItemType Directory `
      -Path $destinationDirectory `
      -Force `
      -ErrorAction Stop | Out-Null
    Copy-Item `
      -LiteralPath $copyItem.Source `
      -Destination $copyItem.Destination `
      -ErrorAction Stop
    if ($copyItem.ExpectedHash -cne
      (& $getRequiredFileSha256 $copyItem.Destination)) {
      throw "Runtime file copy failed its SHA-256 check."
    }
  }

  # claim直前にsource/staging chainとpreflight hashを再検査し、通常の同時変更を拒否する。
  $stagingItem = Get-Item -LiteralPath $stagingFullPath -ErrorAction Stop
  if ($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Runtime staging root changed before atomic claim."
  }
  foreach ($copyItem in $copyPlan) {
    $sourceCursor = $repoRoot
    foreach ($segment in $copyItem.Segments) {
      $sourceCursor = Join-Path $sourceCursor $segment
      $sourceItem = Get-Item -LiteralPath $sourceCursor -ErrorAction Stop
      if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Runtime source changed after its preflight hash."
      }
    }
    if (-not (Test-Path -LiteralPath $copyItem.Source -PathType Leaf) -or
      (& $getRequiredFileSha256 $copyItem.Source) -cne
        $copyItem.ExpectedHash) {
      throw "Runtime source changed after its preflight hash."
    }

    $destinationCursor = $stagingFullPath
    foreach ($segment in $copyItem.Segments) {
      $destinationCursor = Join-Path $destinationCursor $segment
      $destinationItem = Get-Item `
        -LiteralPath $destinationCursor `
        -ErrorAction Stop
      if ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Runtime staging path changed before atomic claim."
      }
    }
    if (-not (Test-Path -LiteralPath $copyItem.Destination -PathType Leaf) -or
      (& $getRequiredFileSha256 $copyItem.Destination) -cne
        $copyItem.ExpectedHash) {
      throw "Runtime staging path changed before atomic claim."
    }
  }
  [IO.Directory]::Move($stagingFullPath, $targetFullPath)
} catch {
  Write-Warning (
    "Install failed. Staging was not removed automatically; " +
    "verify ownership before cleanup: $stagingFullPath"
  )
  throw
}
# runtime-closure-install:end
```

If your agent runtime uses a different skill location, use the same
manifest-driven copy with that documented skill root. The example refuses to
overwrite an existing target, including one created after preflight. It copies
into a unique sibling staging directory and atomically claims the final target
only after the source and staging chains are revalidated against their preflight
SHA-256 values. Run it only from a trusted, quiescent clone: a malicious local
process racing individual path opens is outside this snippet's safety boundary.
On failure it deliberately retains staging because a pathname alone cannot
prove directory ownership; verify ownership before removing it. Review or remove
an old installation separately instead of mixing versions.

## Manual Use

Invoke the skill before finishing Web UI work when browser verification is
relevant. Use it to plan and report:

- Background dev server startup with PID and log capture.
- Bounded health checks.
- Browser verification at around 390 px, 768 px, and 1280 px or wider.
- Screenshot inspection.
- Console and network checks.
- Cleanup and `未確認` items.

## Examples

- [UI verification checklist](examples/ui-verification-checklist.md)
- [Final report template](examples/final-report-template.md)
- [Bounded server runbook](examples/server-runbook.md)
- [Bounded server executable template](examples/server-runbook.ps1)
- [Evidence matrix example](examples/evidence-matrix.md)
- [Failed verification report example](examples/failed-verification-report.md)
- [Protected route blocked verification report](examples/protected-route-report.md)
- [Responsive overflow verification report](examples/responsive-overflow-report.md)
- [Blank render target verification report](examples/blank-render-target-report.md)
- [Hover and focus state verification report](examples/hover-focus-state-report.md)
- [Loading, empty, and error state verification report](examples/loading-empty-error-state-report.md)

All examples are synthetic. They do not include private logs, screenshots,
tokens, auth cookies, or customer data.

## Validation And Scan

Run all local checks before publishing, copying, or opening a pull request.
These are the same four steps CI runs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\scan-private-markers.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-oss-ready.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-whitespace.ps1
```

On macOS, Linux, or any shell with PowerShell 7+, use
`pwsh -NoProfile -File ./scripts/<script-name>.ps1` instead. Run
`check-whitespace.ps1` after committing: it compares against the git empty
tree, so it checks all committed content rather than only the working-tree
diff.

`scan-private-markers.ps1` blocks common secret prefixes (OpenAI, GitHub, Slack,
AWS, Google, Stripe, and PEM private-key forms), private path markers,
unexpected GitHub repository links, email-like values, and absolute Windows path
leaks. It is a best-effort guard and does not guarantee detection of every
secret format, so keep secrets out of the repository regardless of a passing
scan. In a Git repository it compares the index snapshot with stable working-tree
bytes and also scans eligible untracked text files; it does not use the
owner-gated tracked-only proposal. Git subprocesses run inside bounded,
network-disabled process boundaries. Normal linked-worktree Gitfiles are
accepted; symlink/reparse, index-drift, malformed or dangling Git metadata,
scan-wide deadline, and diagnostic byte-budget failures stop closed. Process
bootstrap and Git-isolation failures emit only fixed redacted diagnostics.
The Windows Job boundary retains handle ownership until close succeeds and
falls back to direct child termination plus a bounded close retry; sub-second
timeouts keep their millisecond precision. The same operation deadline starts
before environment preparation and covers launch, containment, target runtime,
and standard streams; cleanup uses one independent absolute slack. Sanitized
Git children are rebuilt from a fixed environment allowlist. On POSIX, both
external and native session launchers publish a ready PID, verify that it is
the process-group leader, and release the target only after that proof.
`assert-oss-ready.ps1` checks the skill front matter, required public
project files, required README sections, broken local Markdown links, mojibake,
placeholder markers, scanner boundary needles, and the exact active CI
trigger/permission/job/step shape. The existing `actions/checkout@v4` reference
is a mutable major tag, not an immutable supply-chain guarantee; changing
workflow files remains an owner-gated operation under `AGENTS.md`. The readiness
check also keeps every public example file, display name, README link, SKILL
link, and report evidence-category set in one exact manifest. It rejects a
missing link, missing state row, example-name drift, nested undeclared file,
comment/fence/section decoy, and contradictory state verdict through seventeen in-memory
hostile mutations. It also runs the server-runbook contract self-test against the
complete PowerShell workflow and a synthetic local HTTP server. The executable
template is
strict UTF-8 without BOM and LF-only. A CommonMark-aware scanner permits one exact
PowerShell fence, and its body must match the template with ordinal comparison;
only four generated read-only `ContainsKey` variants are accepted. It rejects 93 hostile
fixtures that cut the server-entry def-use chain, overwrite the launch splat,
mutate the retained process identity through aliases/dynamic storage, move cleanup
outside `finally`, substitute a task runner, replay raw stderr through direct or
dynamic readers, reflect an absolute path through output/throw sinks, discard the
bounded stop/race handling, remove deterministic disposal, shadow a command,
mutate the poll counter or a critical output target, add a differently formed
CommonMark executable block, drift ordinal canonical bytes, or weaken ordered
failure propagation. Root `param`, `using`, script requirements, named blocks,
and every `trap` are rejected before statement analysis. Variable, command, and member identifiers use
`OrdinalIgnoreCase` after provider/scope normalization. Top-level, verification,
health, polling, cleanup, and all assignment/unary writes use closed executable
sequences. Except for the U+00AD byte-boundary-only fixture, every hostile mutation
must also be rejected when the semantic analyzer is exercised independently of
the byte gate.
The integration also verifies partial-start cleanup without a retained handle, the
PS5.1 natural-exit race, ordered aggregation when stop and both wrapper disposals
all fail, and fixed relative diagnostic metadata without exposing the local root.
`tests/scan-private-markers.Tests.ps1` is a
dependency-free regression suite covering the scanner's detection, redaction,
false-positive guards, binary standard streams, native Git batch bytes, process
tree cleanup, first-call AST bootstrap/mutation/shadow/transitive bypasses,
dangling Git metadata, fixed diagnostics, and Windows PowerShell 5.1 encoding;
run it whenever the scanner changes.

The runtime-closure self-test derives 12 paths from `SKILL.md` and the
public-example manifest, requires the exact 12 raw `SKILL.md` link lines in
fixed order and count, compares the canonical Install section bytes, and parses
its PowerShell with the AST parser. The strict lexical subset also rejects any
raw less-than sign or top-level fence delimiter before Install, character
references outside the canonical section, and raw h1-through-h6 tag-like token
surfaces even inside code spans or escaped prose. It also rejects Setext-like
underline or thematic-break surfaces, including container-prefixed forms. Any
outside hash-sign-bearing line must match the exact ATX-heading allowlist,
order, and count. It rejects 38 representative mutations and uses synthetic
filesystem fixtures for atomic claim,
fail-closed SHA-256 acquisition, source/staging hash checks, failure retention,
and source-mutation detection. This is a deliberately narrow supported surface,
not an arbitrary Markdown or CommonMark parser.

Use your agent runtime's skill validator as an additional check when one is
available.

## Contributing

Contributions are welcome when they keep the skill focused on bounded,
truthful UI verification. See [CONTRIBUTING.md](CONTRIBUTING.md) for the local
development loop, pull request expectations, and review criteria.

## Security

This project is designed to prevent accidental over-claiming and private-data
leakage in verification reports, but it is not a general-purpose security tool.
See [SECURITY.md](SECURITY.md) for reporting guidance and supported scope.

## Limitations

- This skill does not replace accessibility audits, security reviews, usability
  research, or manual product acceptance testing.
- It cannot verify authenticated or protected states without a safe authenticated
  environment.
- It does not install Playwright, browser binaries, or browsers by itself.
- Console and network checks depend on the capabilities of the browser
  automation tool available in the agent environment.

## Non-Goals

- No Playwright icon assets, screenshots, or third-party media.
- No package publishing workflow.
- No GitHub Marketplace listing.
- No GitHub Release workflow.
- No paid API, model, or SaaS dependency.

## Safety Notes

- Use synthetic data in examples and tests.
- Do not send secrets, OAuth credentials, auth cookies, customer data, or
  private logs to external services.
- Do not claim a verification category passed unless it was actually checked.
- Mark unavailable or blocked checks as `未確認`.
- Keep server startup, health checks, browser waits, and cleanup bounded.

## License

MIT. See [LICENSE](LICENSE).
