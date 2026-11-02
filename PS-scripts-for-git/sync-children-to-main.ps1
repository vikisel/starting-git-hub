# sync-children-to-main.ps1
#
# SUMMARY
#   Merges GitHub main INTO the other branches on GitHub, so they catch up with
#   main. Run it after main has changed (git before calls it for you).
#
#   For every child (all GitHub branches except main, or only those named with
#   -Only):
#     - already contains main      -> skipped ("already up to date")
#     - merge would conflict       -> left untouched and reported (you resolve it)
#     - otherwise                  -> main is merged into it in a temporary folder
#                                     and pushed with a plain push, then your
#                                     local copy is moved forward if it can be.
#   -DryRun shows what would happen and pushes nothing.
#
#   It writes only to the children. It never touches main, never rebases, never
#   force-pushes, never resolves conflicts. Merges happen in temporary folders.
#   Your working folder is only touched when the ACTIVE branch was synced: it is
#   then fast-forwarded to GitHub (only if that is a plain fast-forward). Other
#   local branches are fast-forwarded the same way, only on this machine.
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer.
#   Usage:    git sync-children                    (all children)
#             git sync-children -DryRun            (preview)
#             git sync-children -Only branch1,branch2

param(
    [string]$Main = 'main',
    [string[]]$Only = @(),
    [switch]$DryRun
)

# Shared helpers (see shared-functions.ps1). It sits in the same folder as this script.
$common = Join-Path $PSScriptRoot 'shared-functions.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host ("shared-functions.ps1 is missing. It must be in the same folder as this script: " + $PSScriptRoot) -ForegroundColor Red
    exit 1
}
. $common

# Through a git alias, -Only arrives as one text like "a,b". Split it into names.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

# A horizontal line ends a run you typed yourself. Scripts that call each other stay quiet
# (the variable below is inherited by the scripts they call).
$topLevel = -not $env:GIT_SCRIPTS_NESTED

try {

# ---------- checks ----------
Assert-GitRepo

# ---------- 1. fetch ----------
git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    Write-Host "Fetch failed." -ForegroundColor Red
    exit 1
}

git rev-parse --verify --quiet ("refs/remotes/origin/" + $Main) | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ("'" + $Main + "' is not on GitHub yet, so there is nothing to merge into. Publish it first (git after).") -ForegroundColor Red
    exit 1
}

$active = git rev-parse --abbrev-ref HEAD
$remote = @(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/ | Where-Object { $_ -ne 'HEAD' -and $_ -ne $Main })

if ($Only.Count -gt 0) { $targets = @($Only | Where-Object { $_ -ne $Main }) }
else                   { $targets = $remote }

if ($targets.Count -eq 0) {
    Write-Host "No child branches to sync." -ForegroundColor Yellow
    exit 0
}

# ---------- 2. sync each child ----------
$results = @()

foreach ($b in $targets) {
    Write-Host ("=== " + $b + " ===") -ForegroundColor Cyan

    if ($b -notin $remote) {
        $results += ($b + " : NOT FOUND on GitHub")
        continue
    }

    $childRef = "refs/remotes/origin/" + $b
    $mainRef  = "refs/remotes/origin/" + $Main

    git merge-base --is-ancestor $mainRef $childRef
    if ($LASTEXITCODE -eq 0) {
        $results += ($b + " : already up to date")
        continue
    }

    $files = @(Get-Conflicts $childRef $mainRef)
    if ($files.Count -gt 0) {
        $results += ($b + " : CONFLICT in " + ($files -join ', ') + ", left untouched")
        continue
    }

    if ($DryRun) {
        $results += ($b + " : would merge cleanly (dry run, not pushed)")
        continue
    }

    $t = New-TempTree $childRef
    if (-not $t) {
        $results += ($b + " : could not create a temporary folder")
        continue
    }

    git -C $t merge --no-edit $mainRef 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git -C $t merge --abort 2>&1 | Out-Null
        Remove-TempTree $t
        $results += ($b + " : merge failed, left untouched")
        continue
    }

    git -C $t push origin ("HEAD:refs/heads/" + $b) 2>&1 | Out-Null
    $pushed = ($LASTEXITCODE -eq 0)
    Remove-TempTree $t

    if (-not $pushed) {
        $results += ($b + " : PUSH REJECTED (not forced). Someone may have pushed meanwhile, run it again")
        continue
    }

    # move your local copy forward, if there is one and it can simply move forward
    $note = ''
    git rev-parse --verify --quiet ("refs/heads/" + $b) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ($b -eq $active) { git merge --ff-only $childRef 2>&1 | Out-Null }
        else                { git fetch origin ($b + ":" + $b) 2>&1 | Out-Null }
        if ($LASTEXITCODE -ne 0) { $note = " (GitHub is updated, but your local copy has its own changes, so it was not moved; git before will deal with it)" }
    }
    $results += ($b + " : updated and pushed" + $note)
}

# ---------- 3. summary ----------
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
foreach ($line in $results) { Write-Host ("  " + $line) }
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
