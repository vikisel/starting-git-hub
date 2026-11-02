# status-all.ps1
#
# SUMMARY
#   Read-only report of every branch, inside any Git repo hosted on GitHub.
#   It changes no branch, file or setting. The only thing it does is fetch from
#   GitHub (which updates git's copy of GitHub's branches), unless you pass
#   -NoFetch. main is listed first, then the children alphabetically.
#
#   Columns:
#     Local vs GitHub              : the local copy of a branch against its GitHub
#                                    copy (OK, pull N, push N, both changed,
#                                    local only, GitHub only).
#     GitHub branch vs GitHub main : the GitHub copy of a branch against the
#                                    GitHub copy of main (same, behind, ahead,
#                                    diverged: red = it would conflict, "clean" = it would not).
#   A legend is printed under the table.
#
#   -Json prints the same state as JSON and nothing else. git before uses it, so
#   the state is worked out in this one place only.
#
#   When a run you typed yourself ends, it prints a horizontal line and an empty
#   line (scripts that call each other stay quiet; status-all -Json prints nothing
#   extra).
#
#   Requires: Git 2.38 or newer.
#   Usage:    git status-all
#             git status-all -NoFetch      (skip the fetch, use what is already local)
#             git status-all -Json         (for other scripts)

param(
    [string]$Main = 'main',
    [switch]$Json,
    [switch]$NoFetch
)

# Shared helpers (see shared-functions.ps1). It sits in the same folder as this script.
$common = Join-Path $PSScriptRoot 'shared-functions.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host ("shared-functions.ps1 is missing. It must be in the same folder as this script: " + $PSScriptRoot) -ForegroundColor Red
    exit 1
}
. $common

function Fail($message) {
    [Console]::Error.WriteLine($message)
    exit 1
}

# A horizontal line ends a run you typed yourself. Scripts that call each other stay quiet
# (the variable below is inherited by the scripts they call).
$topLevel = (-not $env:GIT_SCRIPTS_NESTED) -and (-not $Json)

try {

# ---------- checks ----------
$gitVersionText = git --version
$gitVersionText = $gitVersionText -replace '^git version (\d+\.\d+).*', '$1'
if ([version]$gitVersionText -lt [version]'2.38') { Fail "Git 2.38 or newer is needed. Please update Git." }

git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "This folder is not a Git repository." }

# ---------- helpers ----------
# Ahead = commits only in $a, Behind = commits only in $b
function Get-Counts($a, $b) {
    $range = $a + "..." + $b
    $text  = git rev-list --left-right --count $range 2>$null
    $p     = $text -split '\s+'
    return [pscustomobject]@{ Ahead = [int]$p[0]; Behind = [int]$p[1] }
}

# GitHub copy of a branch compared with GitHub main.
# State: same, samefiles, behind, ahead, diverged, conflict
function Get-VsMain($childRef, $mainRef) {
    $c = Get-Counts $childRef $mainRef
    $r = [pscustomobject]@{ Text = ''; State = ''; Files = '' }

    if ($c.Ahead -eq 0 -and $c.Behind -eq 0) {
        $r.Text = 'OK'
        $r.State = 'same'
        return $r
    }
    git diff --quiet $mainRef $childRef
    if ($LASTEXITCODE -eq 0) {
        $r.Text = 'OK'
        $r.State = 'samefiles'
        return $r
    }
    if ($c.Ahead -eq 0) {
        $r.Text = 'behind ' + $Main + ' by ' + $c.Behind
        $r.State = 'behind'
        return $r
    }
    if ($c.Behind -eq 0) {
        $r.Text = 'ahead of ' + $Main + ' by ' + $c.Ahead
        $r.State = 'ahead'
        return $r
    }
    $files = @(Get-Conflicts $childRef $mainRef)
    $base = 'behind ' + $Main + ' by ' + $c.Behind + ' and ahead by ' + $c.Ahead
    if ($files.Count -gt 0) {
        $r.Text = $base
        $r.State = 'conflict'
        $r.Files = $files -join ', '
    } else {
        $r.Text = $base + ', clean'
        $r.State = 'diverged'
    }
    return $r
}

# ---------- 1. fetch ----------
if (-not $NoFetch) {
    git fetch origin --prune 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Fetch failed." }
}

git rev-parse --verify --quiet ("refs/remotes/origin/" + $Main) | Out-Null
$mainOnGitHub = ($LASTEXITCODE -eq 0)
if (-not $mainOnGitHub) {
    git rev-parse --verify --quiet ("refs/heads/" + $Main) | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail ("'" + $Main + "' exists neither on GitHub nor in this repo. Use -Main <name> if your main branch is called something else.") }
}

# ---------- 2. read the state ----------
$active = git rev-parse --abbrev-ref HEAD
$local  = @(git for-each-ref --format='%(refname:short)' refs/heads/)
$remote = @(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/ | Where-Object { $_ -ne 'HEAD' })
$kids   = @(($local + $remote) | Where-Object { $_ -ne $Main } | Sort-Object -Unique)
$all    = @($Main) + $kids
$dirty  = [bool](git status --porcelain)
$parked = @(Get-ParkedStashes)

$rows = @()
foreach ($b in $all) {
    $isLocal  = $b -in $local
    $isRemote = $b -in $remote

    $row = [pscustomobject]@{
        Name = $b; Local = ''; GitHubVs = ''; Color = 'Green'
        Dirty = $false; Track = $false; Publish = $false; Push = $false; Pull = $false
        Merge = $false; MergeClean = $false; MergeFiles = ''
        Sync = $false; Land = $false; Conflict = $false; Files = ''; DirtyClash = ''; Stashed = 0
    }
    $row.Stashed = @($parked | Where-Object { $_.Branch -eq $b }).Count

    if ($b -eq $active -and $dirty) { $row.Dirty = $true }

    # local vs GitHub
    if ($isLocal -and -not $isRemote) {
        $row.Local   = 'local only'
        $row.Publish = $true
    }
    elseif ($isRemote -and -not $isLocal) {
        $row.Local = 'GitHub only'
        $row.Track = $true
    }
    else {
        $c = Get-Counts ("refs/heads/" + $b) ("refs/remotes/origin/" + $b)
        if ($c.Ahead -eq 0 -and $c.Behind -eq 0) {
            $row.Local = 'OK'
        }
        elseif ($c.Ahead -eq 0) {
            $row.Local = 'pull ' + $c.Behind
            $row.Pull  = $true
        }
        elseif ($c.Behind -eq 0) {
            $row.Local = 'push ' + $c.Ahead
            $row.Push  = $true
        }
        else {
            $row.Local = 'both changed'
            $row.Merge = $true
            $mf = @(Get-Conflicts ("refs/heads/" + $b) ("refs/remotes/origin/" + $b))
            if ($mf.Count -eq 0) {
                $row.MergeClean = $true
                $row.Local = 'both changed, clean'
            } else {
                $row.MergeFiles = $mf -join ', '
                $row.Local = 'both changed'
            }
        }
    }

    # Uncommitted changes (only the active branch has them): do they touch files that GitHub changed,
    # either on this branch's own GitHub copy or on GitHub's main? Then committing or pulling would conflict.
    if ($row.Dirty) {
        $mine   = @(git diff --name-only HEAD) + @(git ls-files --others --exclude-standard)
        $theirs = @()
        if ($isRemote) {
            $remoteRef = "refs/remotes/origin/" + $b
            $base = git merge-base HEAD $remoteRef 2>$null
            if ($base) { $theirs += @(git diff --name-only $base $remoteRef) }
        }
        if ($b -ne $Main -and ($Main -in $remote)) {
            $mainRemote = "refs/remotes/origin/" + $Main
            $base = git merge-base HEAD $mainRemote 2>$null
            if ($base) { $theirs += @(git diff --name-only $base $mainRemote) }
        }
        $clash = @($mine | Where-Object { $_ -in $theirs } | Select-Object -Unique)
        if ($clash.Count -gt 0) { $row.DirtyClash = $clash -join ', ' }
    }

    # GitHub copy vs GitHub main
    if ($b -eq $Main) {
        $row.GitHubVs = '-'
    }
    elseif ($isRemote -and -not $mainOnGitHub) {
        $row.GitHubVs = $Main + ' not on GitHub yet'
    }
    elseif ($isRemote) {
        $g = Get-VsMain ("refs/remotes/origin/" + $b) ("refs/remotes/origin/" + $Main)
        $row.GitHubVs = $g.Text
        if ($g.State -eq 'behind')   { $row.Sync = $true }
        if ($g.State -eq 'ahead')    { $row.Land = $true }
        if ($g.State -eq 'diverged') { $row.Sync = $true; $row.Land = $true }
        if ($g.State -eq 'conflict') { $row.Conflict = $true; $row.Files = $g.Files }
    }
    else {
        $row.GitHubVs = 'not on GitHub yet'
    }

    # Each column gets its own colour, so you can see which kind of problem it is.
    # The branch name gets the worst of the two (and yellow if it has uncommitted changes).
    $localColor = 'Green'
    if ($row.MergeFiles) { $localColor = 'Red' }
    elseif ($row.Track -or $row.Publish -or $row.Push -or $row.Pull -or $row.Merge) { $localColor = 'Yellow' }

    $vsColor = 'Green'
    if ($row.Conflict) { $vsColor = 'Red' }
    elseif ($row.Sync -or $row.Land) { $vsColor = 'Yellow' }
    elseif ($row.GitHubVs -eq 'not on GitHub yet') { $vsColor = 'DarkGray' }

    $row | Add-Member -NotePropertyName LocalColor -NotePropertyValue $localColor
    $row | Add-Member -NotePropertyName VsColor -NotePropertyValue $vsColor

    if ($localColor -eq 'Red' -or $vsColor -eq 'Red' -or $row.DirtyClash) { $row.Color = 'Red' }
    elseif ($localColor -eq 'Yellow' -or $vsColor -eq 'Yellow' -or $row.Dirty -or $row.Stashed -gt 0) { $row.Color = 'Yellow' }

    $rows += $row
}

# ---------- 3. JSON output (for other scripts) ----------
if ($Json) {
    $out = [pscustomobject]@{ Active = $active; All = @($all); Rows = @($rows) }
    [Console]::Out.Write(($out | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}

# ---------- 4. print the table ----------
$h1 = 'Branch'
$h2 = 'Local vs GitHub'
$h3 = 'GitHub branch vs GitHub ' + $Main
$h4 = 'Uncommitted changes'
$w1 = $h1.Length; $w2 = $h2.Length; $w3 = $h3.Length
foreach ($r in $rows) {
    if ($r.Name.Length     -gt $w1) { $w1 = $r.Name.Length }
    if ($r.Local.Length    -gt $w2) { $w2 = $r.Local.Length }
    if ($r.GitHubVs.Length -gt $w3) { $w3 = $r.GitHubVs.Length }
}
$fmt = " {0} {1,-" + $w1 + "}  {2,-" + $w2 + "}  {3,-" + $w3 + "}  {4}"

Write-Host ""
Write-Host ($fmt -f ' ', $h1, $h2, $h3, $h4) -ForegroundColor Cyan
foreach ($r in $rows) {
    $mark = ' '
    if ($r.Name -eq $active) { $mark = '*' }
    Write-Host (" " + $mark + " ") -NoNewline
    Write-Host ($r.Name.PadRight($w1)) -ForegroundColor $r.Color -NoNewline
    Write-Host "  " -NoNewline
    Write-Host ($r.Local.PadRight($w2)) -ForegroundColor $r.LocalColor -NoNewline
    Write-Host "  " -NoNewline
    Write-Host ($r.GitHubVs.PadRight($w3)) -ForegroundColor $r.VsColor -NoNewline
    Write-Host "  " -NoNewline
    $st = ''
    if ($r.Stashed -gt 0) { $st = 'stashed ' + $r.Stashed }
    if ($r.Name -ne $active) {
        if ($st) { Write-Host $st -ForegroundColor Yellow } else { Write-Host '-' }
    }
    elseif ($r.DirtyClash)    { Write-Host 'yes' -NoNewline -ForegroundColor Red; if ($st) { Write-Host (', ' + $st) -ForegroundColor Yellow } else { Write-Host '' } }
    elseif ($r.Dirty)         { Write-Host 'yes' -NoNewline -ForegroundColor Yellow; if ($st) { Write-Host (', ' + $st) -ForegroundColor Yellow } else { Write-Host '' } }
    elseif ($st)              { Write-Host $st -ForegroundColor Yellow }
    else                      { Write-Host 'OK' -ForegroundColor Green }
}
Write-Host ""
Write-Host "  * = active branch.  Green = nothing to do, yellow = something to do, red = conflict."
Write-Host "  Each column is coloured on its own. The branch name shows the worst of them."
foreach ($r in $rows) {
    if ($r.DirtyClash) {
        Write-Host ("  '" + $r.Name + "': your uncommitted changes conflict with GitHub's new commits in: " + $r.DirtyClash) -ForegroundColor Red
    }
}
exit 0

} finally {
    if ($topLevel) {
        Write-Host ("-" * 60)
        Write-Host ""
    }
}
