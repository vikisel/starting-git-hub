# shared-functions.ps1
#
# SUMMARY
#   Not a command. The helpers that several scripts share, kept in one place so there is
#   one copy of each. Every script loads it with one line, from its own folder:
#       . "$PSScriptRoot/shared-functions.ps1"
#   It is found relative to the script that loads it, so moving or renaming the folder
#   does not break anything (unlike a git alias, which stores the folder path).
#   It must stay in the same folder as the scripts. It has no alias and is never run by itself.
#
#   What is in it:
#     Prompt, Warn, Ask       asking and warning (Enter = yes/do, N = no, E = exit the whole run)
#     Stop-Run, Pass-Exit, Read-Pick, Read-Message   the keys: E ends the whole run, also from inside another script
#     Assert-GitRepo          Git 2.38 or newer, and we are inside a repository
#     Require-Aliases         every git alias a script calls exists and points to a file
#     Get-Conflicts           would merging b into a conflict, and in which files
#     New-TempTree, Remove-TempTree   a temporary folder to merge in without touching yours
#     Get-RepoState           the state of every branch, read through git status-all
#     Switch-KeepWork         switch branch; uncommitted changes are carried along or stashed, you choose
#     Get-ParkedStashes, Restore-Parked   the stashes these scripts made, and bringing them back
#     Get-NotFixableReason    why a conflict cannot be fixed yet (used by both conflict lists)

# Read-Host that never returns $null (for example when the input is closed).
function Prompt($text) {
    $r = Read-Host $text
    if ($null -eq $r) { return '' }
    return $r
}

# "Warning:" in yellow, then the text.
function Warn($text) {
    Write-Host "Warning: " -ForegroundColor Yellow -NoNewline
    Write-Host $text
}

# E ends the whole run, also when this script was started by another one: the one you typed it in
# says so and ends; a script started by another exits with code 20, and the caller (Pass-Exit) ends too.
function Stop-Run {
    Write-Host "Exited here. Nothing further was done." -ForegroundColor Yellow
    if ($topLevel) { exit 0 } else { exit 20 }
}

# Call right after running another script: if you pressed E in it, end this one too.
function Pass-Exit {
    if ($LASTEXITCODE -eq 20) {
        if ($topLevel) { exit 0 } else { exit 20 }
    }
}

# The keys everywhere:  Enter = do what the first option says,  N = no (what that means is written next to it),
# E = exit the whole run.  Every question lists its options one per line and ends with "Choose action:".
function Write-Option($key, $text) {
    Write-Host ("  " + $key.PadRight(8) + " " + $text)
}

# A yes/no question. Enter or y = yes, N = no, E = exit. Returns $true for yes.
function Ask($question, $yes = 'yes, do it', $no = 'no, leave it') {
    Write-Host $question
    Write-Host ""
    Write-Option 'Enter' $yes
    Write-Option 'N' $no
    Write-Option 'E' 'exit the whole run'
    $reply = (Prompt "Choose action").Trim()
    if ($reply -match '^(e|E)$') { Stop-Run }
    return ($reply -eq '' -or $reply -match '^(y|yes)$')
}

# Free text that cannot have a default (a commit message). Empty asks again. Returns '' for N = cancel.
function Read-Message($text) {
    Write-Host $text
    Write-Host ""
    Write-Option 'text' 'type the message'
    Write-Option 'N' "no, don't commit"
    Write-Option 'E' 'exit the whole run'
    while ($true) {
        $r = (Prompt "Choose action").Trim()
        if ($r -match '^(e|E)$') { Stop-Run }
        if ($r -match '^(n|N)$') { return '' }
        if ($r -ne '') { return $r }
    }
}

# Choose among numbered items. Enter = item 1 ($firstText says what that is when it is the only one),
# numbers such as 1,3 = only those, A = all, N = none ($noText says what happens then), E = exit.
# Returns the chosen positions (0-based).
function Read-Pick($count, $lead, $firstText, $allowAll = $true, $noText = 'do nothing now, go on') {
    Write-Host ""
    if ($lead) { Write-Host $lead }
    if ($count -eq 1) { Write-Option 'Enter' $firstText }
    else {
        Write-Option 'Enter' 'do item 1'
        Write-Option 'numbers' 'do only those, e.g. 1,3'
        if ($allowAll) { Write-Option 'A' 'do all of them' }
    }
    Write-Option 'N' $noText
    Write-Option 'E' 'exit the whole run'
    $r = (Prompt "Choose action").Trim()
    if ($r -match '^(e|E)$') { Stop-Run }
    if ($r -match '^(n|N)$') { return @() }
    if ($r -eq '') { return @(0) }
    if ($allowAll -and $r -match '^(a|A)$') { return @(0..($count - 1)) }
    $sel = @()
    foreach ($piece in ($r -split '[,\s]+')) {
        $k = 0
        if ([int]::TryParse($piece, [ref]$k) -and $k -ge 1 -and $k -le $count) { $sel += ($k - 1) }
    }
    return @($sel | Sort-Object -Unique)
}

# Stops the script (exit 1) unless Git is new enough and we are inside a repository.
function Assert-GitRepo {
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
    git remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "This repo has no GitHub connection called 'origin'. Connect it first (git remote add origin <GitHub address>)." -ForegroundColor Red
        exit 1
    }
}

# Every git alias a script calls must be registered and must point to an existing file. Checked
# up front, before anything runs, and the exact command is printed for each one that is not.
function Require-Aliases($names) {
    $files = @{
        'before' = 'git-before.ps1'; 'after' = 'git-after.ps1'; 'land-main' = 'land-main-to-children.ps1'
        'status-all' = 'status-all.ps1'; 'sync-children' = 'sync-children-to-main.ps1'
        'show-conflict' = 'show-conflict.ps1'; 'resolve-conflict' = 'resolve-conflict.ps1'
    }
    $dir = $PSScriptRoot -replace '\\', '/'
    $missing = @()
    foreach ($n in $names) {
        $value = git config --get ("alias." + $n)
        if (-not $value) { $missing += $n; continue }
        # the alias exists: does the file it points to still exist (it will not after a folder was renamed)?
        if ($value -match '-File\s+"?([^"]+?\.ps1)"?\s*$') {
            if (-not (Test-Path -LiteralPath $Matches[1])) { $missing += $n }
        }
    }
    if ($missing.Count -eq 0) { return }
    Write-Host "These git aliases are missing, or point to a file that no longer exists, so this cannot run:" -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host ("  git config --global alias." + $m + " '!powershell -NoProfile -ExecutionPolicy Bypass -File `"" + $dir + "/" + $files[$m] + "`"'")
    }
    Write-Host "Run the line(s) above (change the folder or file name if yours differ), then run this again."
    exit 1
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

# A temporary folder with $ref checked out, to merge in without touching your working folder.
function New-TempTree($ref) {
    $path = Join-Path $env:TEMP ("tmptree-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    git worktree add --detach $path $ref 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $path
}

function Remove-TempTree($path) {
    if ($path) { git worktree remove --force $path 2>&1 | Out-Null }
}

# Asks git status-all for the state of every branch (it does not fetch again).
function Get-RepoState($main) {
    $json = git status-all -Json -NoFetch -Main $main
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        Write-Host "git status-all failed. Is the status-all alias registered?" -ForegroundColor Red
        exit 1
    }
    return (($json -join "`n") | ConvertFrom-Json)
}

# Stashes made by these scripts carry this label, so they can be told apart from your own.
# Returns them newest first: Ref (stash@{n}) and Branch (the branch they were parked on).
function Get-ParkedStashes {
    $out = @()
    foreach ($line in @(git stash list --format='%gd|%gs')) {
        if ($line -match '^(stash@\{\d+\})\|.*parked by scripts on (\S+)\s*$') {
            $out += [pscustomobject]@{ Ref = $Matches[1]; Branch = $Matches[2] }
        }
    }
    return $out
}

# Switches to $branch. No uncommitted changes: a plain switch. With uncommitted changes it asks:
# carry them along (only when the changed files do not differ on that branch, local copy and
# GitHub copy), stash them on the branch you leave, or cancel. $noCarryReason (when given) says
# why carrying is not possible in this case; then only stash or cancel are offered.
# Returns $true only if it switched.
function Switch-KeepWork($branch, $noCarryReason = '') {
    $target = "refs/heads/" + $branch
    git rev-parse --verify --quiet $target | Out-Null
    $hasLocal = ($LASTEXITCODE -eq 0)
    git rev-parse --verify --quiet ("refs/remotes/origin/" + $branch) | Out-Null
    $hasRemote = ($LASTEXITCODE -eq 0)
    if (-not $hasLocal -and -not $hasRemote) {
        Write-Host ("No branch called '" + $branch + "'.") -ForegroundColor Red
        return $false
    }
    if (-not $hasLocal) { $target = "refs/remotes/origin/" + $branch }

    if (-not (git status --porcelain)) {
        git checkout $branch | Out-Host
        return ($LASTEXITCODE -eq 0)
    }

    $current = git rev-parse --abbrev-ref HEAD
    $mine   = @(git diff --name-only HEAD) + @(git ls-files --others --exclude-standard)
    $theirs = @(git diff --name-only HEAD $target)
    if ($hasRemote) { $theirs += @(git diff --name-only HEAD ("refs/remotes/origin/" + $branch)) }
    $clash  = @($mine | Where-Object { $_ -in $theirs } | Select-Object -Unique)

    if ($noCarryReason -or $clash.Count -gt 0) {
        if ($noCarryReason) { Write-Host ("Carry not possible: " + $noCarryReason) -ForegroundColor Red }
        else { Write-Host ("Carry not possible, files differ on '" + $branch + "': " + ($clash -join ', ')) -ForegroundColor Red }
        Write-Host "Your uncommitted changes:"
        Write-Option 'Enter' ("stash them on '" + $current + "', then switch to '" + $branch + "'")
        Write-Option 'N' ("no, stay on '" + $current + "'")
        Write-Option 'E' 'exit the whole run'
        $reply = (Prompt "Choose action").Trim()
        if ($reply -match '^(e|E)$') { Stop-Run }
        $choice = if ($reply -eq '' -or $reply -match '^(s|S)$') { 'S' } else { '' }
    } else {
        Write-Host "Your uncommitted changes:"
        Write-Option 'Enter' ("carry them to '" + $branch + "'")
        Write-Option 'S' ("stash them on '" + $current + "', then switch to '" + $branch + "'")
        Write-Option 'N' ("no, stay on '" + $current + "'")
        Write-Option 'E' 'exit the whole run'
        $reply = (Prompt "Choose action").Trim()
        if ($reply -match '^(e|E)$') { Stop-Run }
        $choice = if ($reply -eq '' -or $reply -match '^(c|C)$') { 'C' } elseif ($reply -match '^(s|S)$') { 'S' } else { '' }
    }
    if ($choice -eq '') { return $false }

    if ($choice -eq 'S') {
        git stash push --include-untracked -m ("parked by scripts on " + $current) | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Could not stash. Nothing was changed." -ForegroundColor Red
            return $false
        }
    }
    git checkout $branch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not switch." -ForegroundColor Red
        if ($choice -eq 'S') {
            git stash pop | Out-Host
            if ($LASTEXITCODE -ne 0) { Write-Host ("Your changes are in the stash labelled 'parked by scripts on " + $current + "'.") -ForegroundColor Yellow }
        }
        return $false
    }
    return $true
}

# Offers to bring back the changes parked on $branch (newest first). Asks for each one.
function Restore-Parked($branch) {
    foreach ($p in @(Get-ParkedStashes | Where-Object { $_.Branch -eq $branch })) {
        if (-not (Ask ("'" + $branch + "' has stashed changes. Restore them now?") 'yes, restore them' 'no, leave them stashed')) { return }
        git stash pop $p.Ref | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Not fully restored (the files overlap with changes here, or conflict). The stash is kept." -ForegroundColor Red
            return
        }
    }
}

# Why a conflict on $branch (merged with $incoming) cannot be fixed yet, or '' when it can. It cannot
# when there is no local branch, or its local copy and its GitHub copy differ (the conflict was
# predicted from the GitHub copy).
function Get-NotFixableReason($branch, $incoming) {
    if ($incoming -eq ("origin/" + $branch)) { return '' }
    git rev-parse --verify --quiet ("refs/heads/" + $branch) | Out-Null
    if ($LASTEXITCODE -ne 0) { return "there is no local branch of that name" }
    git rev-parse --verify --quiet ("refs/remotes/origin/" + $branch) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ((git rev-parse ("refs/heads/" + $branch)) -ne (git rev-parse ("refs/remotes/origin/" + $branch))) {
            return "local and GitHub copy differ"
        }
    }
    return ''
}

# Asks git sync-children to merge main into the given branches. Returns $true if it ran fine.
function Invoke-SyncChildren($names) {
    git sync-children -Main $Main -Only ($names -join ',') | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# Runs one planned action. Returns $true on success. (git output goes to the screen only.)
function Invoke-Action($a) {
    $b = $a.Branch

    if ($a.Type -eq 'Commit') {
        git status --short | Out-Host
        Write-Host "   Everything listed above, including new files, will be committed."
        $msg = Read-Message "Commit message:"
        if ($msg -eq '') {
            Write-Host "   Cancelled, nothing was committed." -ForegroundColor Yellow
            $script:ActionCancelled = $true
            return $false
        }
        git add -A | Out-Host
        git commit -m $msg | Out-Host
        return ($LASTEXITCODE -eq 0)
    }
    if ($a.Type -eq 'Track') {
        git branch --track $b ("origin/" + $b) | Out-Host
        return ($LASTEXITCODE -eq 0)
    }
    if ($a.Type -eq 'Publish') {
        git push -u origin $b | Out-Host
        return ($LASTEXITCODE -eq 0)
    }
    if ($a.Type -eq 'Push') {
        git push origin $b | Out-Host
        return ($LASTEXITCODE -eq 0)
    }
    if ($a.Type -eq 'Pull') {
        if ($a.IsActive) { git merge --ff-only ("origin/" + $b) | Out-Host }
        else             { git fetch origin ($b + ":" + $b) | Out-Host }
        return ($LASTEXITCODE -eq 0)
    }
    if ($a.Type -eq 'MergeBoth') {
        if ($a.IsActive) {
            git merge --no-edit ("origin/" + $b) | Out-Host
            if ($LASTEXITCODE -ne 0) {
                git merge --abort 2>&1 | Out-Null
                return $false
            }
            git push origin $b | Out-Host
            return ($LASTEXITCODE -eq 0)
        }
        $t = New-TempTree ("refs/heads/" + $b)
        if (-not $t) { return $false }
        git -C $t merge --no-edit ("origin/" + $b) | Out-Host
        if ($LASTEXITCODE -ne 0) {
            git -C $t merge --abort 2>&1 | Out-Null
            Remove-TempTree $t
            return $false
        }
        git -C $t push origin ("HEAD:refs/heads/" + $b) | Out-Host
        $ok = ($LASTEXITCODE -eq 0)
        Remove-TempTree $t
        if ($ok) { git fetch origin ($b + ":" + $b) | Out-Host }
        return $ok
    }
    return $false
}

# The Step 1 actions for the current state. If the active branch has uncommitted
# changes the only action is the commit, because the others depend on it.
function Get-Step1Plan($rows, $active) {
    $plan = @()
    $dirtyRow = $rows | Where-Object { $_.Dirty } | Select-Object -First 1
    if ($dirtyRow) {
        $plan += [pscustomobject]@{ Type = 'Commit'; Branch = $dirtyRow.Name; IsActive = $true; Text = ('Commit your uncommitted changes on ' + $dirtyRow.Name) }
        return $plan
    }
    foreach ($r in $rows) { if ($r.Track) { $plan += [pscustomobject]@{ Type = 'Track'; Branch = $r.Name; IsActive = $false; Text = ('Create a local copy of ' + $r.Name + ' (tracks GitHub)') } } }
    foreach ($r in $rows) { if ($r.Publish) { $plan += [pscustomobject]@{ Type = 'Publish'; Branch = $r.Name; IsActive = ($r.Name -eq $active); Text = ('Publish ' + $r.Name + ' to GitHub (new branch)') } } }
    foreach ($r in $rows) { if ($r.Push) { $plan += [pscustomobject]@{ Type = 'Push'; Branch = $r.Name; IsActive = ($r.Name -eq $active); Text = ('Push ' + $r.Name + '  (' + $r.Local + ')') } } }
    foreach ($r in $rows) { if ($r.Pull) { $plan += [pscustomobject]@{ Type = 'Pull'; Branch = $r.Name; IsActive = ($r.Name -eq $active); Text = ('Pull ' + $r.Name + '  (' + $r.Local + ', fast-forward only)') } } }
    foreach ($r in $rows) { if ($r.Merge -and $r.MergeClean) { $plan += [pscustomobject]@{ Type = 'MergeBoth'; Branch = $r.Name; IsActive = ($r.Name -eq $active); Text = ('Merge the GitHub changes into ' + $r.Name + ' and push (both sides changed, no conflict)') } } }
    return $plan
}

# ---------- the list of everything that is open ----------
# Shows the table and ONE list of what is open (red: conflicts, yellow: actions, merging into main, updating the
# children), asks once, does what you chose, checks everything again, and repeats until you stop.
# $scope is 'before' (everything) or 'after' (only commit, publish, push, merging into main, updating the children).
# Returns the last State, the Red items and whether main is stuck, for the caller.
function Invoke-OpenList($Main, $scope) {
    $selfName = if ($scope -eq 'after') { 'git after' } else { 'git before' }
    # One entry of the list. Kind: conflict, resolve (red); action, land, sync (yellow).
    function New-Item2($kind, $text, $branch, $incoming, $plan, $name) {
        return [pscustomobject]@{ Kind = $kind; Text = $text; Branch = $branch; Incoming = $incoming; Plan = $plan; Name = $name; Num = 0; Why = '' }
    }

    $skipTable = $false
    for ($round = 1; $round -le 30; $round++) {
        if (-not $skipTable) {
            if ($round -gt 1) { Write-Host ""; Write-Host "State now:" -ForegroundColor Cyan }
            git status-all -NoFetch -Main $Main
        }
        $skipTable = $false

        $state  = Get-RepoState $Main
        $rows   = @($state.Rows)
        $active = $state.Active
        $mainRow   = $rows | Where-Object { $_.Name -eq $Main } | Select-Object -First 1
        $mainStuck = [bool]($mainRow -and $mainRow.Merge -and -not $mainRow.MergeClean)

        # ----- collect -----
        $red = @(); $actions = @(); $later = @()

        foreach ($r in $rows) {
            if ($r.Merge -and -not $r.MergeClean) {
                $red += New-Item2 'conflict' ($r.Name + " : local and GitHub changes conflict in " + $r.MergeFiles) $r.Name ("origin/" + $r.Name) $null $r.Name
            }
        }
        foreach ($r in $rows) {
            if ($r.Conflict) {
                $t = $r.Name + " : merging " + $Main + " into it conflicts in " + $r.Files
                if ($r.Merge -and -not $r.MergeClean) { $t = $t + "  (after the conflict above)" }
                $red += New-Item2 'conflict' $t $r.Name ("origin/" + $Main) $null $r.Name
            }
        }
        foreach ($r in $rows) {
            if ($r.Dirty) {
                if ($r.DirtyClash) {
                    $red += New-Item2 'resolve' ("Uncommitted changes on " + $r.Name + " conflict with GitHub in " + $r.DirtyClash) $r.Name $null $null $r.Name
                } else {
                    $commitPlan = [pscustomobject]@{ Type = 'Commit'; Branch = $r.Name; IsActive = $true; Text = ('Commit your uncommitted changes on ' + $r.Name) }
                    $actions += New-Item2 'action' ("Uncommitted changes on " + $r.Name) $null $null $commitPlan $r.Name
                }
            }
        }
        $noDirty = @($rows | ForEach-Object { $c = $_.PSObject.Copy(); $c.Dirty = $false; $c })
        foreach ($pl in @(Get-Step1Plan $noDirty $active)) {
            $actions += New-Item2 'action' $pl.Text $null $null $pl $pl.Branch
        }
        if ($scope -eq 'after') { $actions = @($actions | Where-Object { @('Commit', 'Publish', 'Push') -contains $_.Plan.Type }) }
        foreach ($r in $rows) {
            if ($r.Land) { $later += New-Item2 'land' ("Not in " + $Main + " yet: " + $r.Name + "  (" + $r.GitHubVs + ")") $null $null $null $r.Name }
        }
        foreach ($r in $rows) {
            if ($r.Sync) { $later += New-Item2 'sync' ($r.Name + " : still behind " + $Main + "  (" + $r.GitHubVs + ")") $null $null $null $r.Name }
        }

        # Fixing "your uncommitted changes conflict with GitHub" already brings that branch up to date,
        # so a separate pull / merge of the same branch is not listed.
        foreach ($it in @($red | Where-Object { $_.Kind -eq 'resolve' })) {
            $same = @($actions | Where-Object { $_.Plan.Branch -eq $it.Branch -and ($_.Plan.Type -eq 'Pull' -or $_.Plan.Type -eq 'MergeBoth') })
            if ($same.Count -gt 0) {
                $actions = @($actions | Where-Object { $same -notcontains $_ })
                $it.Text = $it.Text + "  (fixing this also brings " + $it.Branch + " up to date)"
            }
        }

        # red conflicts that cannot be fixed yet
        foreach ($it in $red) {
            if ($it.Kind -eq 'conflict') { $it.Why = Get-NotFixableReason $it.Branch $it.Incoming }
        }

        # ----- number what can be done now -----
        # Merging into main and updating the children wait for the commits, pushes, pulls and for main itself.
        $n = 0
        foreach ($it in @($red | Where-Object { -not $_.Why })) { $n++; $it.Num = $n }
        # Everything else for a branch with uncommitted changes waits for the commit (it would not fast-forward otherwise).
        $commitIt = $actions | Where-Object { $_.Plan.Type -eq 'Commit' } | Select-Object -First 1
        foreach ($it in $actions) {
            if ($commitIt -and $it.Plan.Type -ne 'Commit' -and $it.Plan.Branch -eq $commitIt.Plan.Branch) { $it.Why = 'gated'; continue }
            $n++; $it.Num = $n
        }
        foreach ($it in $actions) { if ($it.Why -eq 'gated') { $it.Why = "do item " + $commitIt.Num + " first (" + $commitIt.Text + ")" } }
        # Merging into main and updating the children work on GitHub's copies, so they only wait for what changes
        # the copies they use: main (its conflict, commit, push, merge) and the branch itself (its commit, push,
        # merge). Pulls only change your local copy and hold nothing back.
        function Get-ItemNum($it) { if ($it.Num -gt 0) { return $it.Num } else { return $commitIt.Num } }
        function Get-WaitText($waitFor) {
            $nums = @($waitFor | ForEach-Object { Get-ItemNum $_ } | Sort-Object -Unique)
            return "do " + $(if ($nums.Count -eq 1) { "item " } else { "items " }) + ($nums -join ', ') + " first"
        }
        $changesGitHub = @('Commit', 'Push', 'Publish', 'MergeBoth')
        $mainWait = @($red | Where-Object { $_.Branch -eq $Main -and -not $_.Why }) + @($actions | Where-Object { $_.Plan.Branch -eq $Main -and $changesGitHub -contains $_.Plan.Type })
        foreach ($it in $later) {
            $waitFor = @($mainWait)
            # The branch's own unpushed work must be on GitHub first, otherwise the prediction (made from
            # GitHub's copy) misses it: landing would leave it out, and updating could conflict later.
            $waitFor += @($actions | Where-Object { $_.Plan.Branch -eq $it.Name -and $changesGitHub -contains $_.Plan.Type })
            $waitFor += @($red | Where-Object { $_.Kind -eq 'resolve' -and $_.Branch -eq $it.Name })
            $waitFor = @($waitFor | Where-Object { $_ })
            if ($waitFor.Count -gt 0) { $it.Why = Get-WaitText $waitFor }
            else { $n++; $it.Num = $n }
        }
        $items = @(@($red) + @($actions) + @($later) | Where-Object { $_.Num -gt 0 } | Sort-Object Num)

        # ----- show -----
        Write-Host ""
        if ($red.Count -eq 0 -and $actions.Count -eq 0 -and $later.Count -eq 0) {
            if ($scope -eq 'after') { Write-Host "Done. Everything is committed and on GitHub, and every child that could be updated from main has been." -ForegroundColor Green }
            else { Write-Host "No further action required. All local branches match GitHub, no branch has uncommitted changes, and all branches are up to date with main." -ForegroundColor Green }
            exit 0
        }
        $onNow = git rev-parse --abbrev-ref HEAD
        Write-Host ("You are on '" + $onNow + "'." + $(if (git status --porcelain) { " You have uncommitted changes." } else { "" })) -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Still open:" -ForegroundColor Cyan
        $all = @($red) + @($actions) + @($later)
        # While main has a conflict that is still to be fixed, a conflict with main is only today's picture: it may change.
        $mainItem = $red | Where-Object { $_.Kind -eq 'conflict' -and $_.Branch -eq $Main -and $_.Num -gt 0 } | Select-Object -First 1
        # what can be done now comes first (numbered); what is waiting comes after (dash, and what it waits for)
        foreach ($it in @($all | Where-Object { $_.Num -gt 0 }) + @($all | Where-Object { $_.Num -eq 0 })) {
            $col = 'Yellow'
            if ($it.Kind -eq 'conflict' -or $it.Kind -eq 'resolve') { $col = 'Red' }
            if ($it.Num -gt 0) {
                $tag = ''
                if ($col -eq 'Red' -and $it.Branch -and $it.Branch -ne $onNow) { $tag = "  (switch to " + $it.Branch + ")" }
                Write-Host ("  " + $it.Num + ". " + $it.Text + $tag) -ForegroundColor $col
                if ($mainItem -and $it.Kind -eq 'conflict' -and $it.Incoming -eq ("origin/" + $Main) -and $it.Branch -ne $Main) {
                    Write-Host ("     (?) may change once " + $Main + " is fixed (item " + $mainItem.Num + ")") -ForegroundColor Yellow
                }
            } else {
                $why = $it.Why
                if ($it.Kind -eq 'conflict') {
                    # name the action in this list that has to happen first, when there is one
                    $first = $actions | Where-Object { $_.Name -eq $it.Branch -and $_.Num -gt 0 } | Select-Object -First 1
                    if ($first) { $why = $why + ", do item " + $first.Num + " first" }
                    else        { $why = $why + ", run git before first" }
                }
                Write-Host ("  -  " + $it.Text) -ForegroundColor $col
                Write-Host ("     not fixable yet: " + $why) -ForegroundColor Yellow
                if ($mainItem -and $it.Kind -eq 'conflict' -and $it.Incoming -eq ("origin/" + $Main) -and $it.Branch -ne $Main) {
                    Write-Host ("     (?) may change once " + $Main + " is fixed (item " + $mainItem.Num + ")") -ForegroundColor Yellow
                }
            }
        }
        Write-Host ""
        if ($items.Count -eq 0) {
            Write-Host "Nothing can be fixed right now."
            break
        }

        # ----- pick -----
        Write-Host "What do you want to do?"
        Write-Host ""
        Write-Option 'Enter' ("do item 1: " + $items[0].Text)
        if ($items.Count -gt 1) { Write-Option 'numbers' 'do only those, e.g. 2,3' }
        # "A" never publishes a branch to GitHub nor creates a local copy of one: making a branch appear where it is missing is always your own choice, by number (or Enter on item 1).
        $allOnes = @($items | Where-Object { $_.Kind -ne 'conflict' -and $_.Kind -ne 'resolve' -and -not ($_.Kind -eq 'action' -and @('Publish','Track') -contains $_.Plan.Type) })
        $hasPublish = (@($items | Where-Object { $_.Kind -eq 'action' -and @('Publish','Track') -contains $_.Plan.Type }).Count -gt 0)
        if ($allOnes.Count -gt 1) {
            if ($hasPublish) { Write-Option 'A' 'do all the yellow ones, except making a branch appear on GitHub or locally (pick those by number)' }
            else             { Write-Option 'A' 'do all the yellow ones' }
        }
        Write-Option 'N' $(if ($scope -eq 'after') { 'do nothing now, go on to the summary' } else { 'do nothing now, go on to the branch question' })
        Write-Option 'E' 'exit the whole run'
        $answer = (Prompt "Choose action").Trim()
        if ($answer -match '^(e|E)$') { Stop-Run }
        if ($answer -match '^(n|N)$') { break }
        $picked = @()
        if ($answer -eq '') {
            $picked = @($items[0])
        } elseif ($answer -match '^(a|A)$') {
            $picked = $allOnes
        } else {
            foreach ($piece in ($answer -split '[,\s]+')) {
                $k = 0
                if ([int]::TryParse($piece, [ref]$k)) { $picked += @($items | Where-Object { $_.Num -eq $k }) }
            }
            $picked = @($picked | Sort-Object Num -Unique)
        }
        if ($picked.Count -eq 0) { break }

        # ----- do it: commits, pushes and pulls first, then merging into main, then updating children, a red one last -----
        $failed = $false
        $did    = $false
        $cancelled = $false
        foreach ($it in @($picked | Where-Object { $_.Kind -eq 'action' })) {
            Write-Host ""
            Write-Host ("-> " + $it.Text) -ForegroundColor Cyan
            $script:ActionCancelled = $false
            if (Invoke-Action $it.Plan) { Write-Host "   done" -ForegroundColor Green; $did = $true }
            elseif ($script:ActionCancelled) { Write-Host "   skipped (you chose not to)" -ForegroundColor Yellow; $cancelled = $true }
            else { Write-Host "   NOT DONE, see the message above." -ForegroundColor Red; $failed = $true }
        }
        if (-not $failed -and @($picked | Where-Object { $_.Kind -eq 'land' }).Count -gt 0) {
            Write-Host ""
            $mainBefore = git rev-parse ("refs/remotes/origin/" + $Main)
            $landNames = @($picked | Where-Object { $_.Kind -eq 'land' } | ForEach-Object { $_.Name })
            git land-main -Main $Main -NoFetch -Only ($landNames -join ',')
            Pass-Exit
            $landCode = $LASTEXITCODE
            $mainAfter = git rev-parse ("refs/remotes/origin/" + $Main)
            if ($landCode -eq 2) {
                Write-Host ""
                Write-Host ("Fix the files in Visual Studio Code, commit, sync, then run " + $selfName + " again.") -ForegroundColor Yellow
                exit 0
            }
            if ($landCode -eq 0 -or $landCode -eq 10) {
                if ($mainBefore -ne $mainAfter -or $landCode -eq 10) { $did = $true }
                else { $skipTable = $true }   # you chose not to merge anything: show the list again, not the table
            }
            else {
                Write-Host "git land-main did not finish (see the message above)." -ForegroundColor Red
                $failed = $true
            }
        }
        $syncNames = @($picked | Where-Object { $_.Kind -eq 'sync' } | ForEach-Object { $_.Name })
        if (-not $failed -and $syncNames.Count -gt 0) {
            Write-Host ""
            if (Invoke-SyncChildren $syncNames) { $did = $true }
            else {
                Write-Host "git sync-children did not finish (see the message above)." -ForegroundColor Red
                $failed = $true
            }
        }
        $redPick = @($picked | Where-Object { $_.Kind -eq 'conflict' -or $_.Kind -eq 'resolve' }) | Select-Object -First 1
        if (-not $failed -and $redPick) {
            Write-Host ""
            if ($redPick.Kind -eq 'resolve') { git resolve-conflict $redPick.Branch }
            else                             { git resolve-conflict $redPick.Branch $redPick.Incoming }
            Pass-Exit
            $sc = $LASTEXITCODE
            if ($sc -eq 2) {
                Write-Host ""
                Write-Host ("Fix the files in Visual Studio Code, commit, sync, then run " + $selfName + " again.") -ForegroundColor Yellow
                exit 0
            }
            if ($sc -eq 0) { $did = $true }
            elseif (-not $did) { $skipTable = $true }   # nothing happened: show the list again, not the table
        }

        if ($failed) {
            Write-Host ""
            Write-Host ("Stopped because an action did not finish. Fix it and run " + $selfName + " again.") -ForegroundColor Yellow
            break
        }
        if ($did) { Write-Host ""; Write-Host "Checking everything again." -ForegroundColor Cyan }
        elseif ($cancelled) { $skipTable = $true }   # you cancelled and nothing else happened: show the list again, not the table
    }

    return [pscustomobject]@{ State = $state; Red = $red; MainStuck = $mainStuck }
}
