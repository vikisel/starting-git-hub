# show-conflict.ps1
#
# SUMMARY
#   Read-only. Lists every conflict there is or would be, so you know what needs fixing.
#   It changes nothing: no branch, no file, no setting.
#
#   It lists, red, in this order:
#     - uncommitted changes that would conflict with GitHub if you committed them
#     - branches whose local copy and GitHub copy conflict
#     - branches that conflict with main (GitHub copy of the branch vs GitHub main)
#   Each line names the branch and the files. To fix one, use git resolve-conflict.
#
#   Usage:  git show-conflict
#           git show-conflict <branch>        only that branch
#           -Main <name>                      the name of your main branch (default main)
#
#   It fetches first (when you typed it yourself) and reads the state through git
#   status-all (its alias). Requires: Git 2.38 or newer.
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet).

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Branch,
    [string]$Main = 'main'
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

Require-Aliases @('status-all')

# Fetch first (reads GitHub, changes no branch). Scripts that call this one have just fetched.
if ($topLevel) {
    git fetch origin --prune
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Fetch failed." -ForegroundColor Red
        exit 1
    }
}

# ---------- read the state ----------
$json = git status-all -Json -NoFetch -Main $Main
if ($LASTEXITCODE -ne 0 -or -not $json) {
    Write-Host "git status-all failed." -ForegroundColor Red
    exit 1
}
$state = (($json -join "`n") | ConvertFrom-Json)

$found = @()
foreach ($r in $state.Rows) {
    if ($r.Dirty -and $r.DirtyClash) {
        $found += [pscustomobject]@{ Branch = $r.Name; Text = ($r.Name + " : your uncommitted changes would conflict with GitHub in " + $r.DirtyClash + "  (if you commit them)") }
    }
}
foreach ($r in $state.Rows) {
    if ($r.Merge -and -not $r.MergeClean) {
        $found += [pscustomobject]@{ Branch = $r.Name; Text = ($r.Name + " : local and GitHub changes conflict in " + $r.MergeFiles) }
    }
}
foreach ($r in $state.Rows) {
    if ($r.Conflict) {
        $t = $r.Name + " : merging " + $Main + " into it conflicts in " + $r.Files
        if ($r.Merge -and -not $r.MergeClean) { $t = $t + "  (after the conflict above)" }
        $found += [pscustomobject]@{ Branch = $r.Name; Text = $t }
    }
}
if ($Branch) { $found = @($found | Where-Object { $_.Branch -eq $Branch }) }

if ($found.Count -eq 0) {
    if ($Branch) { Write-Host ("No conflicts for " + $Branch + ", committed or uncommitted.") -ForegroundColor Green }
    else         { Write-Host "No conflicts, committed or uncommitted." -ForegroundColor Green }
    exit 0
}

for ($i = 0; $i -lt $found.Count; $i++) {
    Write-Host ("  " + ($i + 1) + ". " + $found[$i].Text) -ForegroundColor Red
}
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
