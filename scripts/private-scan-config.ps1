# Single source of truth for directory names that local validation scripts skip.
# Dot-source this file so scan-private-markers.ps1 and assert-oss-ready.ps1 stay
# in sync instead of each carrying its own copy (review S-1: avoid drift).
#
# Note: scan-private-markers.ps1 scans the Git index snapshot and every eligible
# working-tree text file, including untracked files. These directory names mirror
# repository-local generated-output exclusions; they do not turn the scanner into
# tracked-only mode or exempt ordinary untracked source/docs from inspection.

$script:PrivateScanExcludedDirectories = @(
  ".git",
  ".claude",
  ".codex",
  "node_modules",
  ".ui-verification",
  "playwright-report",
  "test-results",
  "coverage",
  "dist",
  "build"
)

function Get-PrivateScanExcludedDirectories {
  return $script:PrivateScanExcludedDirectories
}
