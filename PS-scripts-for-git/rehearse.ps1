# rehearse.ps1
#
# SUMMARY
#   Runs git before, git after or git land-main as a full rehearsal on a throwaway copy of your
#   repo, so you see the real run with the real questions and the real results,
#   and nothing real changes. git before -DryRun and git after -DryRun call this.
#
#   What it does:
#     1. Fetches from GitHub (the only thing it does to your real repo; it only
#        updates git's copy of GitHub's branches).
#     2. Copies the whole repo folder (files, uncommitted changes and branches)
#        into a temporary folder.
#     3. Makes a temporary stand-in for GitHub next to it, filled with what
#        GitHub has right now, and points the copy at it. Hooks are switched off
#        in the copy.
#     4. Runs the command in the copy. You answer the questions as in a real run,
#        and every commit, pull, push and merge happens in the copy only.
#     5. Deletes the temporary folder.
#
#   Your real folder, your real branches and GitHub are not touched. The copy has
#   the size of your repo folder, so a repo with very large files needs that much
#   free disk space for a moment. Run it from the main folder of the repo, not
#   from a linked worktree.
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer, and the aliases of the command you rehearse.
#   Usage:    rehearse.ps1 before | after | land-main   (the scripts run it for -DryRun; it has no alias)
#   (or simply git before -DryRun / git after -DryRun / git land-main -DryRun)

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('before', 'after', 'land', 'land-main')]
    [string]$Command,
    [string]$Main = 'main'
)

if ($Command -eq 'land') { $Command = 'land-main' }   # the old name still works

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

Require-Aliases @($Command)

$top = (git rev-parse --show-toplevel)
if (-not (Test-Path -LiteralPath (Join-Path $top '.git') -PathType Container)) {
    Write-Host "Run this from the main folder of the repo, not from a linked worktree." -ForegroundColor Red
    exit 1
}

# ---------- 1. fetch (reads GitHub, changes no branch) ----------
git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    Write-Host "Fetch failed." -ForegroundColor Red
    exit 1
}

# ---------- 2. copy the repo, 3. stand-in for GitHub ----------
$root = Join-Path $env:TEMP ("rehearse-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$work = Join-Path $root 'work'
$fake = Join-Path $root 'github.git'
$ok   = $false

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Write-Host "Copying the repo to a temporary folder..."
    Copy-Item -LiteralPath $top -Destination $work -Recurse -Force
    git worktree prune 2>$null | Out-Null

    git init --bare --quiet $fake
    $refspecs = @()
    foreach ($b in @(git -C $work for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/)) {
        if ($b -ne 'HEAD') { $refspecs += ("refs/remotes/origin/" + $b + ":refs/heads/" + $b) }
    }
    if ($refspecs.Count -gt 0) {
        git -C $work push --quiet $fake @refspecs 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not fill the temporary stand-in for GitHub." }
    }

    git -C $work remote set-url origin $fake
    git -C $work config --unset remote.origin.pushurl 2>$null | Out-Null
    git -C $work config core.hooksPath (Join-Path $root 'no-hooks')
    git -C $work fetch --quiet --prune origin 2>&1 | Out-Null
    $ok = $true
}
catch {
    Write-Host ("Could not prepare the rehearsal: " + $_.Exception.Message) -ForegroundColor Red
}

# ---------- 4. run the command in the copy ----------
if ($ok) {
    Write-Host ""
    Write-Host "REHEARSAL: this runs on a throwaway copy. Your real repo and GitHub are not touched." -ForegroundColor Cyan
    Write-Host ""
    Push-Location $work
    $env:GIT_SCRIPTS_REHEARSAL = '1'
    try {
        git $Command -Main $Main
    }
    finally {
        Remove-Item Env:GIT_SCRIPTS_REHEARSAL -ErrorAction SilentlyContinue
        Pop-Location
    }
    Write-Host ""
    Write-Host "REHEARSAL finished. Nothing in your real repo or on GitHub was changed." -ForegroundColor Cyan
}

# ---------- 5. clean up ----------
if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $ok) { exit 1 }
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
