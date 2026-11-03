# git-before.ps1
#
# SUMMARY
#   Run at the start of a work session, inside any Git repo hosted on GitHub.
#   It fetches GitHub once, prints the table from git status-all, and then shows ONE
#   list of everything that is open ("Still open"), in this order:
#     - conflicts (red) that can be fixed now, with a number; a conflict on another
#       branch is tagged (switch to <branch>)
#     - conflicts that cannot be fixed yet, with a dash and the reason (for example
#       "local and GitHub copy differ, do item 2 first (Push c3)")
#     - the actions (yellow): commit, create a local copy, publish, push, pull
#       (fast-forward only), and merge GitHub's changes in when both sides changed
#       without a conflict. Everything else for a branch with uncommitted changes
#       waits for its commit.
#     - merging finished branches into main (git land-main) and updating the children
#       from main (git sync-children). These wait until the actions above are done
#       and main itself has no conflict; until then they show a dash and "do items
#       ... first".
#   One question, with its options one per line: Enter = do item 1, numbers
#   (e.g. 2,3), A = all the yellow ones, N = do nothing now, E = exit the whole run. A red number opens the fix in Visual Studio Code (git resolve-conflict),
#   a yellow one does it. After something was done everything is checked again and
#   the new table and list are shown. N leaves the list.
#   If everything is fine it says "No further action required" and ends.
#
#   Then it warns when main is in conflict, lets you stay on the branch or switch
#   (uncommitted changes: carry them along or stash them) and offers to restore changes
#   stashed on the branch you stay on. It does nothing to that branch that was not in the
#   list. The closing line says whether that branch really matches GitHub.
#
#   It never rebases, never force-pushes, never resolves conflicts itself, and
#   never deletes a branch or any of your files (only its own temporary
#   folders). Main is only changed through git land-main, for the branches you pick.
#   Branches other than the active one are merged in temporary folders. The
#   active branch is changed in your working folder (commit, pull, merge).
#
#   -DryRun rehearses the whole run: the same questions and the same results,
#   but on a throwaway copy of the repo and a stand-in for GitHub, so nothing real
#   changes (it runs rehearse.ps1 before).
#   It accepts no other options than -Main <name> and -DryRun.
#
#   It calls other tools only through their git aliases, never by file name:
#     git status-all     (the table, and the state as JSON)
#     git sync-children  (merges main into the children)
#     git land-main           (merges the branches you pick into main)
#     git resolve-conflict  (only when you pick a conflict from the list)
#     rehearse.ps1       (only for -DryRun; run from this folder, it has no alias)
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer, and the two aliases above.
#   Usage:    git before
#             git before -DryRun

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
$env:GIT_SCRIPTS_FROM_BEFORE = '1'   # tells git land-main it was called from here

try {

# ---------- checks ----------
Assert-GitRepo

Require-Aliases (@('status-all', 'sync-children', 'land-main', 'resolve-conflict'))

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
    & (Join-Path $PSScriptRoot 'rehearse.ps1') before -Main $Main
    $rc = $LASTEXITCODE; if ($rc -eq 20) { $rc = 0 }
    exit $rc
}

# ---------- 1. fetch ----------
git fetch origin --prune
if ($LASTEXITCODE -ne 0) {
    Write-Host "Fetch failed." -ForegroundColor Red
    exit 1
}

$activeNow = git rev-parse --abbrev-ref HEAD
if ($activeNow -eq 'HEAD') {
    Write-Host "Detached HEAD. Check out a branch first." -ForegroundColor Red
    exit 1
}

# ---------- 2. the list of everything that is open (shared with git after) ----------
$openList  = Invoke-OpenList $Main 'before'
$state     = $openList.State
$red       = $openList.Red
$mainStuck = $openList.MainStuck

Write-Host ""
# Working on main while it has a conflict means fixing that conflict first.
$mainFix = $red | Where-Object { $_.Kind -eq 'conflict' -and $_.Branch -eq $Main -and -not $_.Why } | Select-Object -First 1
if ($mainStuck) {
    $activeNow = git rev-parse --abbrev-ref HEAD
    if ($activeNow -eq $Main) {
        Warn ($Main + " has an unresolved conflict, so working on " + $Main + " means fixing it first. To work on another branch, enter its name.")
    } else {
        Warn ($Main + " has an unresolved conflict. Work on '" + $activeNow + "' is fine, but merging into " + $Main + " or updating the children from it has to wait until " + $Main + " is handled.")
    }
}
while ($true) {
    $active = git rev-parse --abbrev-ref HEAD
    Write-Host ""
    $fixMain = ($mainStuck -and $active -eq $Main -and $mainFix)
    if ($fixMain) { Write-Option 'Enter' ("work on '" + $active + "': fix its conflict now in Visual Studio Code") }
    else          { Write-Option 'Enter' ("stay on '" + $active + "'") }
    Write-Option 'name' 'type another branch name to switch to it'
    Write-Option 'E' 'exit the whole run'
    $answer = (Prompt "Choose action").Trim()
    if ($answer -match '^(e|E)$') { Stop-Run }
    if ($answer.Trim() -eq '' -or $answer -eq $active) {
        if (-not $fixMain) { break }
        Write-Host ""
        git resolve-conflict $mainFix.Branch $mainFix.Incoming
        Pass-Exit
        $sc = $LASTEXITCODE
        if ($sc -eq 2) {
            Write-Host ""
            Write-Host "Fix the files in Visual Studio Code, commit, sync, then run git before again." -ForegroundColor Yellow
            exit 0
        }
        if ($sc -eq 0) {
            Write-Host ""
            Write-Host "Checking everything again." -ForegroundColor Cyan
            git before -Main $Main
            Pass-Exit
            exit $LASTEXITCODE
        }
        continue
    }
    if ($answer -notin @($state.All)) {
        Write-Host ("No branch called '" + $answer + "'.") -ForegroundColor Red
        continue
    }
    if (Switch-KeepWork $answer) {
        Write-Host ""
        git status-all -NoFetch -Main $Main
    }
}
Restore-Parked (git rev-parse --abbrev-ref HEAD)

# ---------- 5. the closing line says what is true now ----------
# (Everything that can be done to the branch you stay on was in the list above; N there means nothing is done.)
$active = git rev-parse --abbrev-ref HEAD

$final = Get-RepoState $Main
$me    = $final.Rows | Where-Object { $_.Name -eq $active } | Select-Object -First 1

# Other branches that still have something open (same meaning as the "Still open" lists)
$others = @()
foreach ($r in $final.Rows) {
    if ($r.Name -eq $active) { continue }
    if ($r.Dirty -or $r.Local -ne 'OK' -or $r.Sync -or $r.Conflict -or $r.Land) { $others += $r.Name }
}

Write-Host ""
if ($me.Dirty) {
    Write-Host ("'" + $active + "' still has uncommitted changes.") -ForegroundColor Yellow
}
elseif ($me.Local -ne 'OK') {
    Write-Host ("'" + $active + "' does not match GitHub yet (local vs GitHub: " + $me.Local + ").") -ForegroundColor Yellow
}
elseif ($others.Count -gt 0) {
    Write-Host ("'" + $active + "' is committed and matches GitHub, but these branches still have open items: " + ($others -join ', ') + ".") -ForegroundColor Yellow
}
else {
    Write-Host "Nothing is open on any branch." -ForegroundColor Green
}

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
