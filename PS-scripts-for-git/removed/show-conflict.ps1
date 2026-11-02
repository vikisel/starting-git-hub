# show-conflict.ps1
#
# SUMMARY
#   Read-only. Shows why two branches conflict, so you can see what to fix by hand.
#   It changes nothing: no branch, file or setting.
#
#   For two branches (or any two refs) A and B it first finds the files that would
#   conflict if B were merged into A. For each such file it prints two diffs, both
#   measured from the point where A and B split:
#     - what A changed
#     - what B changed
#   The lines that both diffs touch are where the conflict is.
#
#   Names are shown plainly: refs/heads/X as "local X", refs/remotes/origin/X as
#   "GitHub X". git before and git land offer this view when a conflict needs you.
#
#   It calls no other tool. Requires: Git 2.38 or newer.
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet).
#
#   Usage:    git show-conflict refs/remotes/origin/main refs/remotes/origin/some-branch
#             git show-conflict main some-branch

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$A,
    [Parameter(Mandatory = $true, Position = 1)][string]$B
)

# A horizontal line ends a run you typed yourself. Scripts that call each other stay quiet
# (the variable below is inherited by the scripts they call).
$topLevel = -not $env:GIT_SCRIPTS_NESTED

try {

# ---------- checks ----------
$gitVersionText = git --version
$gitVersionText = $gitVersionText -replace '^git version (\d+\.\d+).*', '$1'
if ([version]$gitVersionText -lt [version]'2.38') {
    Write-Host "Git 2.38 or newer is needed. Please update Git." -ForegroundColor Red
    exit 1
}

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "This folder is not a Git repository." -ForegroundColor Red
    exit 1
}

foreach ($ref in @($A, $B)) {
    git rev-parse --verify --quiet ($ref + "^{commit}") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("'" + $ref + "' is not a branch or commit here.") -ForegroundColor Red
        exit 1
    }
}

# ---------- helpers ----------
function Plain-Name($ref) {
    if ($ref -like 'refs/heads/*')           { return ('local ' + $ref.Substring(11)) }
    if ($ref -like 'refs/remotes/origin/*')  { return ('GitHub ' + $ref.Substring(20)) }
    return $ref
}

# Conflicted files if $b were merged into $a (empty = clean).
function Get-Conflicts($a, $b) {
    $out  = @(git merge-tree --write-tree --name-only $a $b 2>$null)
    $code = $LASTEXITCODE
    if ($code -eq 0) { return @() }
    if ($code -ne 1) { return @('(could not check)') }
    $lines = @($out | Select-Object -Skip 1)
    $files = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '') { break }
        $files += $lines[$i]
    }
    return $files
}

# ---------- show the two sides ----------
$nameA = Plain-Name $A
$nameB = Plain-Name $B
$files = @(Get-Conflicts $A $B)

if ($files.Count -eq 0) {
    Write-Host ("No conflict between " + $nameA + " and " + $nameB + ".") -ForegroundColor Green
    exit 0
}

Write-Host ("Merging " + $nameB + " into " + $nameA + " conflicts in " + $files.Count + " file(s). Each diff starts where the two split.") -ForegroundColor Cyan

foreach ($f in $files) {
    Write-Host ""
    Write-Host ("=== " + $f + " ===") -ForegroundColor White
    Write-Host ("--- what " + $nameA + " changed ---") -ForegroundColor Cyan
    git --no-pager diff ($B + "..." + $A) -- $f | Out-Host
    Write-Host ("--- what " + $nameB + " changed ---") -ForegroundColor Cyan
    git --no-pager diff ($A + "..." + $B) -- $f | Out-Host
}
Write-Host ""
Write-Host "The lines that both sides changed are where the conflict is."
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
