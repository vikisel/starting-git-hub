# resolve-conflict.ps1
#
# SUMMARY
#   Fixes a conflict in Visual Studio Code (merge editor). It is the "do it" partner
#   of git show-conflict, which only lists the conflicts and changes nothing.
#
#   Usage:  git resolve-conflict                    lists the open conflicts, you pick one
#           git resolve-conflict <branch>           that branch's conflict (see order below)
#           git resolve-conflict <branch> <incoming>
#               <branch>   a local branch, the one that receives the changes
#               <incoming> what is merged into it (for example origin/main)
#           -Main <name>   the name of your main branch (default main)
#   The list holds: uncommitted changes that would conflict if you committed them
#   (these come first, a merge needs a clean folder), then local-vs-GitHub conflicts
#   of a branch, then conflicts of a branch with main.
#
#   Order of work:
#   1. Fetches (when you typed it yourself) and checks, changing nothing: no merge is
#      already open, the branch exists locally, the local branch matches its GitHub
#      copy (unless the incoming side is that copy), the folder is clean (or you chose
#      an uncommitted conflict), and 'code' (Visual Studio Code) is available.
#   2. Shows what it would do, then asks [y/N]:
#        - commit your uncommitted changes (only for an uncommitted conflict; first it asks
#          for a branch name if they belong on another branch, then it looks again from
#          the start on that branch; Enter keeps them here. It lists
#          the files and uses the message "WIP before merging <incoming>", which you
#          can change later with git commit --amend)
#        - switch to <branch> (only if it is not the active branch)
#        - git merge <incoming>   (it stops at the conflict and leaves the markers)
#        - open the conflicting files in Visual Studio Code
#      Nothing is resolved by this script. You fix the files in the merge editor.
#   3. It then waits. You fix the files, commit and sync (push) in Visual Studio
#      Code, and press Enter here (A = abort the merge, E = exit the whole run and leave it open). It fetches and checks that the merge
#      is committed, nothing is uncommitted and the branch is on GitHub. If not, it
#      says what is missing and waits again.
#   4. When you typed it yourself, it then says whether other conflicts are left (and lists them).
#
#   Exit codes (for the scripts that call it): 0 = no conflict, or fixed and on
#   GitHub; 1 = could not start (the reason is shown); 2 = you chose E while it was
#   unfinished (the merge may still be open); 3 = you said no, or a dry run; 4 = you
#   chose A and the merge was aborted.
#
#   -DryRun shows what it would do and changes nothing. During a rehearsal
#   (git before -DryRun, git land -DryRun) it behaves as -DryRun.
#
#   It never rebases, never force-pushes, never resolves a conflict, never deletes
#   anything. It calls git status-all (through its alias) to read the state.
#   Requires: Git 2.38 or newer.
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet).

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Branch,
    [Parameter(Position = 1)][string]$Incoming,
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
$env:GIT_SCRIPTS_NESTED = '1'   # scripts called from here stay quiet

try {

# ---------- checks ----------
Assert-GitRepo
$top = (git rev-parse --show-toplevel) -replace '/', [IO.Path]::DirectorySeparatorChar

$preview = $DryRun -or [bool]$env:GIT_SCRIPTS_REHEARSAL

# Fetch first (reads GitHub, changes no branch). Scripts that call this one have just fetched.
if ($topLevel) {
    git fetch origin --prune
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Fetch failed." -ForegroundColor Red
        exit 1
    }
}

git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "A merge is already open in this folder. Finish it first (fix the files, git add ., git commit) or give up with: git merge --abort" -ForegroundColor Red
    exit 1
}

$listed = $false  # true when you chose from a list of several
$picked = $null   # the list entry you chose (when you did not give both names yourself)

# A reason why the chosen conflict cannot be fixed now. When you chose it from a list, say why and
# show the list again (work on another one, or Enter to leave); otherwise just stop.
function Refuse($text) {
    Write-Host $text -ForegroundColor Red
    if ($listed) {
        Write-Host ""
        git resolve-conflict -Main $Main
        Pass-Exit
        exit $LASTEXITCODE
    }
    exit 1
}

# ---------- which conflict? ----------
# With no arguments it lists the open conflicts and you pick one. With only a branch it takes that
# branch's conflict (its local-vs-GitHub conflict first, otherwise its conflict with main).
if (-not $Branch -or -not $Incoming) {
    Require-Aliases @('status-all')
    $json = git status-all -Json -NoFetch -Main $Main
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        Write-Host "git status-all failed." -ForegroundColor Red
        exit 1
    }
    $state = (($json -join "`n") | ConvertFrom-Json)
    $found = @()
    foreach ($r in $state.Rows) {
        if ($r.Dirty -and $r.DirtyClash) {
            $inc = "origin/" + $Main
            if ($r.Pull -or $r.Merge) { $inc = "origin/" + $r.Name }
            $found += [pscustomobject]@{ Kind = 'dirty'; Branch = $r.Name; Incoming = $inc; Files = $r.DirtyClash; Text = ($r.Name + " : your uncommitted changes would conflict with GitHub in " + $r.DirtyClash + "  (they have to be committed first)") }
        }
    }
    foreach ($r in $state.Rows) {
        if ($r.Merge -and -not $r.MergeClean) {
            $found += [pscustomobject]@{ Kind = 'merge'; Branch = $r.Name; Incoming = ("origin/" + $r.Name); Files = $r.MergeFiles; Text = ($r.Name + " : local and GitHub changes conflict in " + $r.MergeFiles) }
        }
    }
    foreach ($r in $state.Rows) {
        if ($r.Conflict) {
            $t = $r.Name + " : merging " + $Main + " into it conflicts in " + $r.Files
            if ($r.Merge -and -not $r.MergeClean) { $t = $t + "  (after the conflict above)" }
            $found += [pscustomobject]@{ Kind = 'merge'; Branch = $r.Name; Incoming = ("origin/" + $Main); Files = $r.Files; Text = $t }
        }
    }
    if ($Branch) { $found = @($found | Where-Object { $_.Branch -eq $Branch }) }

    if ($found.Count -eq 0) {
        if ($Branch) { Write-Host ("No conflict found for " + $Branch + ".") -ForegroundColor Green }
        else         { Write-Host "No conflicts." -ForegroundColor Green }
        exit 0
    }
    $choice = $found[0]
    if ($found.Count -gt 1 -and -not $Branch) {
        # Which ones can be fixed now? Not when there is no local branch, or its local copy and its GitHub copy differ.
        foreach ($f in $found) {
            $why = Get-NotFixableReason $f.Branch $f.Incoming
            if ($why) { $why = $why + ", run git before first" }
            $f | Add-Member -NotePropertyName Why -NotePropertyValue $why
        }
        $fixable = @($found | Where-Object { -not $_.Why })

        $listed = $true
        $onNow = git branch --show-current
        Write-Host ("You are on '" + $onNow + "'." + $(if (git status --porcelain) { " You have uncommitted changes." } else { "" })) -ForegroundColor Cyan
        Write-Host ""
        # what can be fixed now comes first (numbered); what is waiting comes after (dash and the reason)
        $mainItem = $fixable | Where-Object { $_.Branch -eq $Main } | Select-Object -First 1
        $n = 0
        foreach ($f in @($fixable) + @($found | Where-Object { $_.Why })) {
            $tag = ""
            if ($f.Branch -ne $onNow) { $tag = "  (switch to " + $f.Branch + ")" }
            if ($f.Why) {
                Write-Host ("  -  " + $f.Text) -ForegroundColor Red
                Write-Host ("     not fixable yet: " + $f.Why) -ForegroundColor Yellow
            } else {
                $n++
                Write-Host ("  " + $n + ". " + $f.Text + $tag) -ForegroundColor Red
            }
            # while main has a conflict still to be fixed, a conflict with main is only today's picture
            if ($mainItem -and $f.Incoming -eq ("origin/" + $Main) -and $f.Branch -ne $Main) {
                $mn = ([array]::IndexOf(@($fixable), $mainItem)) + 1
                Write-Host ("     (?) may change once " + $Main + " is fixed (item " + $mn + ")") -ForegroundColor Yellow
            }
        }
        Write-Host ""
        if ($fixable.Count -eq 0) {
            Write-Host "Nothing can be fixed right now." 
            exit 3
        }
        $pickIdx = @(Read-Pick $fixable.Count "Which conflict do you want to fix?" ("fix " + $fixable[0].Branch) $false "no, nothing is changed")
        if ($pickIdx.Count -eq 0) {
            Write-Host "Nothing was changed."
            exit 3
        }
        $choice = $fixable[$pickIdx[0]]
        Write-Host ""
    }
    $Branch   = $choice.Branch
    $Incoming = $choice.Incoming
    $picked   = $choice
}

git rev-parse --verify --quiet ("refs/heads/" + $Branch) | Out-Null
if ($LASTEXITCODE -ne 0) {
    Refuse ("Cannot fix '" + $Branch + "' yet: there is no local branch of that name. Run git before first, it can create it from GitHub, then try again.")
}

git rev-parse --verify --quiet ($Incoming + "^{commit}") | Out-Null
if ($LASTEXITCODE -ne 0) {
    Refuse ("Cannot fix '" + $Branch + "': '" + $Incoming + "' is not a branch or commit here.")
}

# The conflict was predicted from the GitHub copy of the branch. Make sure the local branch is the same.
if ($Incoming -ne ("origin/" + $Branch)) {
    git rev-parse --verify --quiet ("refs/remotes/origin/" + $Branch) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $localSha  = git rev-parse ("refs/heads/" + $Branch)
        $githubSha = git rev-parse ("refs/remotes/origin/" + $Branch)
        if ($localSha -ne $githubSha) {
            Refuse ("Cannot fix '" + $Branch + "' yet: its local copy and its GitHub copy are not the same. Run git before first (it pulls and pushes), then try again.")
        }
    }
}

$willCommit = [bool]($picked -and $picked.Kind -eq 'dirty')
$dirty = @(git status --porcelain)
if ($dirty.Count -gt 0 -and -not $willCommit) {
    $activeNow = git branch --show-current
    if ($activeNow -ne $Branch) {
        if ($preview) {
            Write-Host ("Dry run: it would ask what to do with your uncommitted changes (carry them to '" + $Branch + "' or stash them) before switching.") -ForegroundColor Cyan
        } else {
            if (-not (Switch-KeepWork $Branch 'merging needs a clean folder, and carried changes would be in the way.')) {
                if ($listed) {
                    Write-Host ""
                    git resolve-conflict -Main $Main
                    Pass-Exit
                    exit $LASTEXITCODE
                }
                Write-Host "Nothing was changed."
                exit 3
            }
            # on that branch the changes (if carried) may be in the way: look again from the start
            Write-Host ""
            git resolve-conflict $Branch $Incoming -Main $Main
            Pass-Exit
            exit $LASTEXITCODE
        }
    } else {
        Write-Host "This folder has uncommitted changes. Commit them first (git before does that), then try again." -ForegroundColor Red
        exit 1
    }
}

if (-not $preview) {
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Host "The command 'code' (Visual Studio Code) was not found. In Visual Studio Code: Ctrl+Shift+P, 'Shell Command: Install code command in PATH'." -ForegroundColor Red
        exit 1
    }
}

function Plain-Name($ref) {
    if ($ref -like 'origin/*') { return ('GitHub ' + $ref.Substring(7)) }
    return ('local ' + $ref)
}

# ---------- predict ----------
$files = @(Get-Conflicts ("refs/heads/" + $Branch) $Incoming)
if ($willCommit) { $files = @($picked.Files -split ', ') }
if ($files.Count -eq 0) {
    Write-Host ("No conflict between local " + $Branch + " and " + (Plain-Name $Incoming) + ".") -ForegroundColor Green
    exit 0
}

if ($willCommit) { Write-Host ("Committing your changes and merging " + (Plain-Name $Incoming) + " into local " + $Branch + " conflicts in " + $files.Count + " file(s):") -ForegroundColor Cyan }
else             { Write-Host ("Merging " + (Plain-Name $Incoming) + " into local " + $Branch + " conflicts in " + $files.Count + " file(s):") -ForegroundColor Cyan }
foreach ($f in $files) { Write-Host ("  " + $f) }

$active = git branch --show-current
Write-Host ""
Write-Host ("You are on '" + $active + "'.") -ForegroundColor Cyan
if ($willCommit) {
    Write-Host ("These uncommitted changes will be committed on '" + $active + "'. If they belong on another branch, enter its name.") -ForegroundColor Yellow
    while (-not $preview) {
        Write-Host ""
        Write-Option 'Enter' ("continue on '" + $active + "'")
        Write-Option 'name' 'type another branch name to switch to it'
        Write-Option 'E' 'exit the whole run'
        $other = (Prompt "Choose action").Trim()
        if ($other -match '^(e|E)$') { Stop-Run }
        if ($other -eq '' -or $other -eq $active) { break }

        if (-not (Switch-KeepWork $other)) { continue }
        # on the new branch the conflicts are different: look again from the start
        Write-Host ""
        git resolve-conflict -Main $Main
        Pass-Exit
        exit $LASTEXITCODE
    }
}
Write-Host "This would:"
$n = 1
if ($willCommit) {
    Write-Host ("  " + $n + ". commit your uncommitted changes, new files included, with the message 'WIP before merging " + $Incoming + "':"); $n++
    foreach ($line in @(git status --short)) { Write-Host ("       " + $line) }
}
if ($active -ne $Branch) { Write-Host ("  " + $n + ". switch to " + $Branch + "  (you are on " + $active + ")"); $n++ }
Write-Host ("  " + $n + ". git merge " + $Incoming + "  (it stops at the conflict and leaves the markers in the files)"); $n++
Write-Host ("  " + $n + ". open the conflicting files in Visual Studio Code, where you fix them in the merge editor")

if ($preview) {
    Write-Host ""
    Write-Host "Dry run: nothing was changed." -ForegroundColor Cyan
    exit 3
}

Write-Host ""
# Choosing it from a list, or being started by another script, already was the question.
$confirmed = ($listed -or -not $topLevel)
if (-not $confirmed -and -not (Ask "Do this now?" "yes, merge and open the conflict in Visual Studio Code" "no, nothing is changed")) {
    Write-Host "Nothing was changed."
    exit 3
}

# ---------- do it ----------
if ($willCommit) {
    git status --short | Out-Host
    git add -A | Out-Host
    git commit -m ("WIP before merging " + $Incoming) | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "The commit did not go through. Nothing else was done." -ForegroundColor Red
        exit 1
    }
}
if ($active -ne $Branch) {
    git switch $Branch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("Could not switch to " + $Branch + ". Nothing else was done.") -ForegroundColor Red
        exit 1
    }
}

git merge --no-edit $Incoming | Out-Host

$open = @(git diff --name-only --diff-filter=U)
if ($open.Count -eq 0) {
    Write-Host ""
    Write-Host "The merge went through without a conflict. It still has to be pushed." -ForegroundColor Green
    exit 0
}

$paths = @()
foreach ($f in $open) { $paths += (Join-Path $top ($f -replace '/', [IO.Path]::DirectorySeparatorChar)) }
& code -r $top @paths

Write-Host ""
Write-Host ("Opened " + $open.Count + " file(s) in Visual Studio Code. In each one click 'Resolve in Merge Editor', choose, save.") -ForegroundColor Cyan
Write-Host "Then in Visual Studio Code: commit, sync (push)."
Write-Host "To give up, press A below: it aborts the merge."

# ---------- wait, then check that it is really finished ----------
# Returns the reason it is not finished yet, or '' when it is.
function Get-Problem {
    git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $left = @(git diff --name-only --diff-filter=U)
        if ($left.Count -gt 0) { return ("The merge is not finished. These files still have conflicts: " + ($left -join ', ')) }
        return "The merge is not finished: all files are fixed but not committed yet. Commit in Visual Studio Code."
    }
    $changes = @(git status --porcelain)
    if ($changes.Count -gt 0) {
        return ("There are uncommitted changes: " + (($changes | ForEach-Object { $_.Trim() }) -join ', ') + ". Commit them in Visual Studio Code.")
    }
    git rev-parse --verify --quiet ("refs/remotes/origin/" + $Branch) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $counts = (git rev-list --left-right --count ("refs/heads/" + $Branch + "...refs/remotes/origin/" + $Branch)) -split '\s+'
        if ([int]$counts[0] -gt 0) {
            return ("Local " + $Branch + " has " + $counts[0] + " commit(s) that GitHub does not have yet. Sync (push) in Visual Studio Code.")
        }
    }
    return ''
}

while ($true) {
    Write-Host ""
    Write-Option 'Enter' 'check now: I have committed and synced'
    Write-Option 'A' 'abort the merge and go back to how things were'
    Write-Option 'E' 'exit the whole run and leave the merge open'
    $r = Prompt "Choose action"
    if ($r -match '^(a|A)$') {
        git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "There is no open merge to abort." -ForegroundColor Yellow
            continue
        }
        git merge --abort | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Merge aborted. Your folder is as it was before the merge." -ForegroundColor Yellow
            exit 4
        }
        Write-Host "The merge could not be aborted. It is still open." -ForegroundColor Red
        exit 2
    }
    if ($r -match '^(e|E)$') {
        Write-Host "Left as it is. If the merge is still open, finish it or abort it with: git merge --abort" -ForegroundColor Yellow
        exit 2
    }
    git fetch origin --prune --quiet
    $problem = Get-Problem
    if ($problem -eq '') { break }
    Write-Host $problem -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("Done: local " + $Branch + " is fixed, committed and on GitHub.") -ForegroundColor Green
if ($topLevel) {
    # typed by you: say whether other conflicts are left (the scripts that call this one look at everything themselves)
    $json2 = git status-all -Json -NoFetch -Main $Main
    if ($LASTEXITCODE -eq 0 -and $json2) {
        $rows2 = @((($json2 -join "`n") | ConvertFrom-Json).Rows)
        $left = @()
        foreach ($r in $rows2) {
            if ($r.Dirty -and $r.DirtyClash) { $left += ($r.Name + " : uncommitted changes would conflict with GitHub in " + $r.DirtyClash) }
            if ($r.Merge -and -not $r.MergeClean) { $left += ($r.Name + " : local and GitHub changes conflict in " + $r.MergeFiles) }
            if ($r.Conflict) { $left += ($r.Name + " : merging " + $Main + " into it conflicts in " + $r.Files) }
        }
        if ($left.Count -eq 0) {
            Write-Host "No other conflicts left." -ForegroundColor Green
        } else {
            Write-Host ($left.Count.ToString() + " other conflict(s) left:") -ForegroundColor Red
            foreach ($l in $left) { Write-Host ("  " + $l) -ForegroundColor Red }
        }
    }
}
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
