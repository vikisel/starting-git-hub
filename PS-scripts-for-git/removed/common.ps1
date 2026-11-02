# common.ps1
#
# SUMMARY
#   Not a command. The helpers that several scripts share, kept in one place so there is
#   one copy of each. Every script loads it with one line, from its own folder:
#       . "$PSScriptRoot/common.ps1"
#   It is found relative to the script that loads it, so moving or renaming the folder
#   does not break anything (unlike a git alias, which stores the folder path).
#   It must stay in the same folder as the scripts. It has no alias and is never run by itself.
#
#   What is in it:
#     Prompt, Warn, Ask       asking and warning
#     Assert-GitRepo          Git 2.38 or newer, and we are inside a repository
#     Require-Aliases         every git alias a script calls exists and points to a file
#     Get-Conflicts           would merging b into a conflict, and in which files
#     New-TempTree, Remove-TempTree   a temporary folder to merge in without touching yours
#     Get-RepoState           the state of every branch, read through git status-all
#     Switch-KeepWork         switch branch; uncommitted changes are carried along or stashed, you choose
#     Get-ParkedStashes, Restore-Parked   the stashes these scripts made, and bringing them back

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

function Ask($question) {
    $reply = Prompt ($question + " [y/N]")
    return ($reply -match '^(y|yes)$')
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
}

# Every git alias a script calls must be registered and must point to an existing file. Checked
# up front, before anything runs, and the exact command is printed for each one that is not.
function Require-Aliases($names) {
    $files = @{
        'before' = 'git-before.ps1'; 'after' = 'git-after.ps1'; 'land' = 'land.ps1'
        'status-all' = 'status-all.ps1'; 'sync-children' = 'sync-children.ps1'
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
# GitHub copy), stash them on the branch you leave, or cancel. Returns $true only if it switched.
function Switch-KeepWork($branch) {
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

    if ($clash.Count -gt 0) {
        Write-Host ("Carry not possible, files differ on '" + $branch + "': " + ($clash -join ', ')) -ForegroundColor Red
        $reply = Prompt ("S = stash them on '" + $current + "', Enter = cancel")
        $choice = if ($reply.Trim() -match '^(s|S)$') { 'S' } else { '' }
    } else {
        $reply = Prompt ("Your uncommitted changes: C = carry them to '" + $branch + "', S = stash them on '" + $current + "', Enter = cancel")
        $choice = if ($reply.Trim() -match '^(c|C)$') { 'C' } elseif ($reply.Trim() -match '^(s|S)$') { 'S' } else { '' }
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
        if (-not (Ask ("'" + $branch + "' has stashed changes. Restore them now?"))) { return }
        git stash pop $p.Ref | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Not fully restored (the files overlap with changes here, or conflict). The stash is kept." -ForegroundColor Red
            return
        }
    }
}
