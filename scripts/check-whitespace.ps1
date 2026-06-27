param()

$ErrorActionPreference = "Stop"

# Single entry point for the whitespace lint so CI and contributors call the
# same command and the git empty-tree hash lives in exactly one place
# (review M-3). Comparing against the empty tree checks every committed line,
# matching CI; a bare `git diff --check` only inspects the working-tree diff and
# passes on a clean tree, which misleads contributors.
$emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

& git diff --check $emptyTreeHash HEAD
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
  Write-Output "Whitespace check failed: trailing whitespace or conflict markers found."
  exit $exitCode
}

Write-Output "Whitespace check passed."
