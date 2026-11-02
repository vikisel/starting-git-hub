# git-after.ps1
#
# SUMMARY
#   Run at the end of a work session, inside any Git repo hosted on GitHub, so
#   that nothing you did stays only on this machine. Everything is asked first.
#
#   It fetches, prints the table from git status-all and then ONE list of what is
#   open, the same list and the same keys as in git before, but limited to putting
#   your work on GitHub: commit the uncommitted changes, publish local-only
#   branches, push, merge finished branches into main (git land) and update the
#   children from main (git sync-children). Conflicts are shown as well, and you
#   can fix them from the list. Items that have to wait for another one show a
#   dash and what they wait for. Pulls and merges of other branches are left to
#   git before.
#   Enter = do item 1, numbers (e.g. 2,3), A = all the yellow ones, N = do nothing
#   now, E = exit the whole run. After something was done everything is checked
#   again. The closing line lists what is still open (uncommitted, not pushed,
#   children still behind main), or says Done.
#
#   It never rebases, never
#   force-pushes, never resolves conflicts, and never deletes a branch or a
#   file. Main is only changed through git land, for the branches you pick.
#   -DryRun rehearses the whole run: the same questions and the same results,
#   but on a throwaway copy of the repo and a stand-in for GitHub, so nothing real
#   changes (it runs rehearse.ps1 after).
#   It accepts no other options than -Main <name> and -DryRun; anything else is
#   an error.
#
#   It calls other tools only through their git aliases, never by file name:
#     git status-all     (the table, and the state as JSON)
#     git sync-children  (merges main into the children)
#     git land           (merges the branches you pick into main)
#     rehearse.ps1       (only for -DryRun; run from this folder, it has no alias)
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer, and the two aliases above.
#   Usage:    git after
#             git after -DryRun

[CmdletBinding()]
param(
    [string]$Main = 'main',
    [switch]$DryRun
)

# Shared helpers (see shared-functions.ps1). It sits in the same folder as this script.
$common = Join-Path $PSScriptRoot 'shared-functions.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host ("shared-functions.ps1 is missing. It must be in the same folder as this script: " + $PSScriptRoot) -ForegroundColor Red
    exit 1
}
. $common

# A horizontal line ends a run you typed yourself. Scripts that call each other stay quiet
# (the variable below is inherited by the scripts they call).
$topLevel = -not $env:GIT_SCRIPTS_NESTED
$env:GIT_SCRIPTS_NESTED = '1'

try {

# ---------- checks ----------
Assert-GitRepo

Require-Aliases (@('status-all', 'sync-children', 'land', 'resolve-conflict'))

# A merge that is still open (conflicts being fixed) must be finished or given up first,
# otherwise its half-fixed files would look like ordinary uncommitted changes.
git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "A merge is still open in this folder, so nothing was done." -ForegroundColor Red
    $unmerged = @(git diff --name-only --diff-filter=U)
    if ($unmerged.Count -gt 0) {
        Write-Host "These files still have conflicts:"
        foreach ($u in $unmerged) { Write-Host ("  " + $u) }
    }
    Write-Host "Fix them (Visual Studio Code), then:  git add .   git commit --no-edit   and run this again."
    Write-Host "To give up instead:  git merge --abort"
    exit 1
}

# ---------- dry run: rehearse the whole thing on a throwaway copy ----------
if ($DryRun) {
    $env:GIT_SCRIPTS_NESTED = '1'   # the rule is printed once, by this script
    & (Join-Path $PSScriptRoot 'rehearse.ps1') after -Main $Main
    $rc = $LASTEXITCODE; if ($rc -eq 20) { $rc = 0 }
    exit $rc
}

# ---------- 1. fetch and show the table ----------
git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    Write-Host "Fetch failed." -ForegroundColor Red
    exit 1
}

$active = git rev-parse --abbrev-ref HEAD
if ($active -eq 'HEAD') {
    Write-Host "Detached HEAD. Check out a branch first." -ForegroundColor Red
    exit 1
}

# ---------- 2. the list of what is open (the same list as in git before, limited to putting work on GitHub) ----------
$openList = Invoke-OpenList $Main 'after'
$state    = $openList.State

# ---------- 3. closing line: say what is really true ----------
$rows = @($state.Rows)
$open = @()
foreach ($r in $rows) {
    if ($r.Dirty)   { $open += ($r.Name + " : uncommitted changes") }
    if ($r.Publish) { $open += ($r.Name + " : not on GitHub yet") }
    if ($r.Push)    { $open += ($r.Name + " : you have commits GitHub lacks (" + $r.Local + ")") }
    if ($r.Sync)    { $open += ($r.Name + " : still behind " + $Main + " on GitHub") }
}

Write-Host ""
if ($open.Count -eq 0) {
    Write-Host "Done. Everything is committed and on GitHub, and every child that could be updated from main has been." -ForegroundColor Green
} else {
    Write-Host "Still open:" -ForegroundColor Yellow
    foreach ($line in $open) { Write-Host ("  - " + $line) }
}

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
