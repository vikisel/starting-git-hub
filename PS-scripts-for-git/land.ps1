# land.ps1
#
# SUMMARY
#   Merges finished branches INTO main on GitHub, when you choose to. Use it on
#   its own (git land) or let git before / git after call it. It is the only
#   script in this set that changes main, and only for branches you pick.
#
#   1. It fetches (unless -NoFetch), then looks at your local main against
#      GitHub's main first. If your local main has commits GitHub lacks, or both
#      sides changed, it stops and tells you what to do (push or git before
#      first), because landing would build on GitHub's main without them. If main
#      is the branch you are on and has uncommitted changes, it prints a Warning.
#      Then it compares every GitHub branch with GitHub main (through git
#      status-all). It prints the branches it checked but left
#      out because they have nothing main lacks (for example children that are
#      only behind main), so a short list is never a mystery.
#   2. Branches that have work main lacks and would merge cleanly are listed
#      numbered. You answer Enter = item 1, numbers (e.g. 1,3), A = all, N = none, E = exit the whole run.
#      Enter is the answer for "not now, something else is running in parallel".
#   3. Branches that would conflict with main are not touched. It says so, lists
#      one line each. You can enter a number to fix that one now in Visual Studio Code
#      (git resolve-conflict); N = go on without fixing.
#   4. For every branch you picked, it checks again that the merge is clean, merges
#      it into main with a merge commit in a temporary folder, and pushes with a
#      plain push. If GitHub refuses (main protected, or a pull request is
#      required, or someone pushed meanwhile) it says so and changes nothing.
#      Branches are merged one after the other, each into the main the previous
#      one produced.
#   5. Your local main is then moved forward, only if that is a plain
#      fast-forward.
#
#   Merging into main changes main, so the children that are behind it need
#   updating again (git sync-children, which git before and git after offer
#   next). When some children are behind main it prints a Warning about that.
#
#   It never force-pushes, never rebases, never resolves conflicts, never deletes
#   a branch or a file. Your working folder is only touched when main is the
#   active branch and gets fast-forwarded.
#   -DryRun rehearses the whole run on a throwaway copy of the repo and a
#   stand-in for GitHub, so nothing real changes (it runs rehearse.ps1 land).
#
#   It calls other tools only through their git aliases, never by file name:
#     git status-all     (the state of every branch as JSON)
#     git resolve-conflict  (only when you pick a conflicting branch to fix in Visual Studio Code)
#     rehearse.ps1       (only for -DryRun; run from this folder, it has no alias)
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer, and the aliases above.
#   Usage:    git land
#             git land -NoFetch    (when the caller has just fetched)
#             git land -DryRun
#             git land -Only c1,c2   (used by git before: the branches you already chose in its list; nothing more is asked)

[CmdletBinding()]
param(
    [string]$Main = 'main',
    [switch]$NoFetch,
    [switch]$DryRun,
    [string[]]$Only
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
$env:GIT_SCRIPTS_NESTED = '1'   # scripts called from here stay quiet

try {

# ---------- checks ----------
Assert-GitRepo

# A merge that is still open (conflicts being fixed) must be finished or given up first.
git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "A merge is still open in this folder, so nothing was done." -ForegroundColor Red
    Write-Host "Fix it (Visual Studio Code), then:  git add .   git commit --no-edit   and run this again."
    Write-Host "To give up instead:  git merge --abort"
    exit 1
}

Require-Aliases (@('status-all', 'resolve-conflict'))

# ---------- dry run: rehearse the whole thing on a throwaway copy ----------
if ($DryRun) {
    $env:GIT_SCRIPTS_NESTED = '1'   # the rule is printed once, by this script
    & (Join-Path $PSScriptRoot 'rehearse.ps1') land -Main $Main
    $rc = $LASTEXITCODE; if ($rc -eq 20) { $rc = 0 }
    exit $rc
}

# ---------- 1. fetch ----------
if (-not $NoFetch) {
    git fetch origin --prune
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Fetch failed." -ForegroundColor Red
        exit 1
    }
}

git rev-parse --verify --quiet ("refs/remotes/origin/" + $Main) | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ("'" + $Main + "' is not on GitHub yet, so there is nothing to merge into. Publish it first (git after).") -ForegroundColor Red
    exit 1
}

# ---------- 2. what can be merged into main ----------
$json = git status-all -Json -NoFetch -Main $Main
if ($LASTEXITCODE -ne 0 -or -not $json) {
    Write-Host "git status-all failed. Is the status-all alias registered?" -ForegroundColor Red
    exit 1
}
$state    = ($json -join "`n") | ConvertFrom-Json

# ---------- 2a. your local main against GitHub's main, before anything is offered ----------
$mainRow = $state.Rows | Where-Object { $_.Name -eq $Main } | Select-Object -First 1
if ($mainRow.Push) {
    Write-Host ("Your local " + $Main + " has commits that GitHub's " + $Main + " lacks (" + $mainRow.Local + ").") -ForegroundColor Yellow
    Write-Host ("  Landing builds on GitHub's " + $Main + " without them, and your local " + $Main + " could no longer simply move forward.")
    Write-Host ("  Push them first (git after, or git before), then run git land again.")
    exit 0
}
if ($mainRow.Merge) {
    Write-Host ("Your local " + $Main + " and GitHub's " + $Main + " both have new commits (" + $mainRow.Local + ").") -ForegroundColor Yellow
    Write-Host ("  Sort that out first with git before, then run git land again.")
    exit 0
}
if ($mainRow.Dirty) {
    Warn ("'" + $Main + "' has uncommitted changes. Landing does not touch them, but moving your local " + $Main + " forward at the end may be refused if the same files changed.")
}

$rows     = @($state.Rows | Where-Object { $_.Name -ne $Main })
$ready    = @($rows | Where-Object { $_.Land })
$conflict = @($rows | Where-Object { $_.Conflict })
$behind   = @($rows | Where-Object { $_.Sync -and -not $_.Land })   # children that only need main's commits

# Started by git before? Its list already showed everything and you already chose, so this stays short.
$fromBefore = [bool]$env:GIT_SCRIPTS_FROM_BEFORE
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only.Count -gt 0) { $ready = @($ready | Where-Object { $_.Name -in $Only }) }

# Say what was looked at and left out, so a short list is never a mystery.
$skipped = @($rows | Where-Object { -not $_.Land -and -not $_.Conflict })
if ($skipped.Count -gt 0 -and -not $fromBefore) {
    Write-Host ""
    Write-Host ("Checked, but nothing to merge into " + $Main + " (they have no commits that " + $Main + " lacks):") -ForegroundColor Cyan
    foreach ($r in $skipped) { Write-Host ("  " + $r.Name + "  -  " + $r.GitHubVs) }
}

if ($ready.Count -eq 0 -and $conflict.Count -eq 0) {
    Write-Host ("Nothing to merge into " + $Main + ".")
    exit 0
}

# ---------- 3. conflicts need you ----------
$ci = 0
$again = if ($fromBefore) { 'git before' } else { 'git land' }
if ($fromBefore) { $conflict = @() }   # they are in git before's list as red items
foreach ($r in $conflict) {
    $ci++
    Write-Host ""
    Write-Host ($ci.ToString() + ". " + $r.Name + "  -  " + $r.GitHubVs + "  (cannot be merged into " + $Main + " automatically, conflict in " + $r.Files + ")") -ForegroundColor Red
}
if ($conflict.Count -gt 0) {
    Write-Host ""
    $pickIdx = @(Read-Pick $conflict.Count "Fix a conflict now in Visual Studio Code?" ("fix " + $conflict[0].Name + " in Visual Studio Code") $false "no, go on without fixing")
    if ($pickIdx.Count -gt 0) {
        $r = $conflict[$pickIdx[0]]
        git resolve-conflict $r.Name ("origin/" + $Main)
        Pass-Exit
        $sc = $LASTEXITCODE
        if ($sc -eq 2) {
            Write-Host ""
            Write-Host ("Fix the files in Visual Studio Code, commit, sync, then run " + $again + " again.") -ForegroundColor Yellow
            if ($fromBefore) { exit 2 } else { exit 0 }
        }
        if ($sc -eq 0) {
            # fixed and on GitHub: start over with the new state
            if ($fromBefore) { exit 10 }
            Write-Host ""
            git status-all -Main $Main
            git land -Main $Main
            Pass-Exit
            exit $LASTEXITCODE
        }
    }
}
if ($ready.Count -eq 0) { exit 0 }

# ---------- 4. choose ----------
if ($Only.Count -eq 0) {
Write-Host ""
Write-Host ("Ready to merge into " + $Main + " on GitHub:") -ForegroundColor Cyan
for ($i = 0; $i -lt $ready.Count; $i++) {
    Write-Host ("  " + ($i + 1) + ". " + $ready[$i].Name + "  -  " + $ready[$i].GitHubVs)
}
}
if ($behind.Count -gt 0 -and -not $fromBefore) {
    Warn ("Merging into " + $Main + " changes " + $Main + ", so the children that are behind it ("  + (($behind | ForEach-Object { $_.Name }) -join ', ') + ") will need updating again.")
}

if ($Only.Count -gt 0) { $selected = @(0..($ready.Count - 1)) }   # chosen in git before's list
else { $selected = @(Read-Pick $ready.Count ("Merge into " + $Main + ": which branches?") ("merge " + $ready[0].Name + " into " + $Main) $true ("merge nothing into " + $Main)) }
$selected = @($selected | Sort-Object -Unique)
if ($selected.Count -eq 0) {
    Write-Host ("Nothing merged into " + $Main + ".")
    exit 0
}

# ---------- 5. merge the chosen branches into main ----------
$active  = git rev-parse --abbrev-ref HEAD
$mainRef = "refs/remotes/origin/" + $Main
$results = @()
$landed  = 0

foreach ($i in $selected) {
    $b        = $ready[$i].Name
    $childRef = "refs/remotes/origin/" + $b
    Write-Host ""
    Write-Host ("=== " + $b + " ===") -ForegroundColor Cyan

    $files = @(Get-Conflicts $mainRef $childRef)
    if ($files.Count -gt 0) {
        $results += ($b + " : CONFLICT in " + ($files -join ', ') + " (after the previous merges), left untouched")
        continue
    }

    $t = New-TempTree $mainRef
    if (-not $t) {
        $results += ($b + " : could not create a temporary folder")
        continue
    }

    git -C $t merge --no-ff -m ("Merge branch '" + $b + "'") $childRef 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git -C $t merge --abort 2>&1 | Out-Null
        Remove-TempTree $t
        $results += ($b + " : merge failed, left untouched")
        continue
    }

    git -C $t push origin ("HEAD:refs/heads/" + $Main) | Out-Host
    $pushed = ($LASTEXITCODE -eq 0)
    Remove-TempTree $t

    if (-not $pushed) {
        $results += ($b + " : PUSH REJECTED (not forced). " + $Main + " may be protected or need a pull request, or someone pushed meanwhile")
        continue
    }
    $landed++
    $results += ($b + " : merged into " + $Main + " and pushed")
}

# ---------- 6. move your local main forward, if it is a plain fast-forward ----------
if ($landed -gt 0) {
    git rev-parse --verify --quiet ("refs/heads/" + $Main) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ($active -eq $Main) { git merge --ff-only $mainRef 2>&1 | Out-Null }
        else                   { git fetch origin ($Main + ":" + $Main) 2>&1 | Out-Null }
        if ($LASTEXITCODE -ne 0) {
            $results += ("Your local " + $Main + " has its own changes, so it was not moved forward (GitHub's " + $Main + " is updated). git before can deal with it.")
        }
    }
}

# ---------- 7. summary ----------
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
foreach ($line in $results) { Write-Host ("  " + $line) }
if ($landed -gt 0 -and $behind.Count -gt 0 -and -not $fromBefore) {
    Write-Host ("  " + $Main + " changed: update the children again with git sync-children.")
}
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
