# Single source of truth for directory names that local validation scripts skip.
# Dot-source this file so scan-private-markers.ps1 and assert-oss-ready.ps1 stay
# in sync instead of each carrying its own copy (review S-1: avoid drift).
#
# Note: scan-private-markers.ps1 scans every text file under the repository root,
# not only git-tracked files. These directory names mirror the repository-root
# .gitignore (.claude/.codex are ignored globally and locally) so an untracked
# working-tree artifact does not fail the scan before it is committed.

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
