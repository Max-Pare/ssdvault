# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Massimo Parenti - https://github.com/Max-Pare/ssdvault

<#
SSDVault (Windows) - versioned, encrypted backup of a portable SSD to the local disk of
every PC it gets plugged into. Runs on the built-in Windows PowerShell 5.1.

  ssdvault install   [-RepoRoot <dir>] [-ResticPath <restic.exe>]
  ssdvault register  <drive> [-Name <name>]
  ssdvault run       [-Path <drive>]
  ssdvault status
  ssdvault log
  ssdvault restic    <vault> <restic arguments...>
  ssdvault stop
  ssdvault uninstall

Ground rules:
  - Data flows one way: drive -> local repository. Nothing is ever restored, synced back
    or deleted on the drive automatically.
  - Nothing found on the drive is executed; the marker files are validated as data.
  - No network: the repository is a local folder, restic never leaves this machine.

Deliberately no param() block: arguments are parsed by hand so that restic options such
as --target pass through `ssdvault restic` untouched.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Not under AppData on purpose: terminals hosted by some packaged (MSIX) desktop apps get
# their AppData writes silently redirected to a private per-app folder, and the scheduled
# tasks would never see the files. The user profile root is not redirected.
$AppDir   = if ($env:SSDVAULT_HOME) { $env:SSDVAULT_HOME } else { Join-Path $env:USERPROFILE '.ssdvault' }
$BinDir   = Join-Path $AppDir 'bin'
$VaultDir = Join-Path $AppDir 'vaults'
$KeyDir   = Join-Path $AppDir 'keys'
$StateDir = Join-Path $AppDir 'state'
$LogDir   = Join-Path $AppDir 'logs'
$ConfFile = Join-Path $AppDir 'config.json'

$MarkerDir   = '.ssdvault'
$TaskFolder  = '\SSDVault\'
$Keep        = @('--keep-within', '2d', '--keep-daily', '14', '--keep-weekly', '8', '--keep-monthly', '24', '--keep-yearly', '5')
$PruneEvery  = 24 * 3600
$CheckEvery  = 7 * 24 * 3600
$MinInterval = @{ plug = 300; timer = 1500; manual = 0 }
$PlugWait    = 60
$Utf8        = New-Object System.Text.UTF8Encoding $false

$script:Restic = $null
$script:RepoRoot = $null
$script:ResticVersion = $null

$DefaultExcludes = @'
# SSDVault exclude patterns (restic syntax), used by every PC this drive visits.
# A pattern without a leading slash matches that name at any depth.
# To skip a single folder without editing this file, put an empty file named
# .nobackup inside it. Folders containing a CACHEDIR.TAG file are skipped too.

# Node / Next / React: rebuilt from package.json + the lockfile
node_modules
.next
.nuxt
.svelte-kit
.turbo
.parcel-cache
.vite
.vercel
.expo
.angular

# Python
__pycache__
.venv
.mypy_cache
.pytest_cache
.ruff_cache

# Blender: numbered save versions (the snapshots replace them) and half-written saves
*.blend[0-9]
*.blend[0-9][0-9]
*.blend@

# Operating system clutter
?RECYCLE.BIN
System Volume Information
.Trash-*
.Spotlight-V100
.fseventsd
Thumbs.db
desktop.ini
.DS_Store
'@

$DriveReadme = @'
This folder marks the drive for SSDVault, a backup tool.

  id            identity of this drive. Do not edit it or copy it to another drive.
  name          short name used for the backup folders on each PC
  excludes.txt  what NOT to back up. Edit freely; every PC uses it.
  history.log   which PC backed this drive up, and when

Deleting this folder stops the automatic backups on every PC.
'@

function Show-Help {
    @'
SSDVault - versioned, encrypted backup of a portable SSD to this PC's local disk.

  ssdvault install   [-RepoRoot <dir>] [-ResticPath <exe>]  set up the scheduled tasks (once per PC)
  ssdvault register  <drive> [-Name <name>]  mark the drive (first time only) and create
                                             its repository on this PC
  ssdvault run       [-Path <drive>]         back up the connected drives now
  ssdvault status                            last backups, connected drives, repo sizes
  ssdvault log                               recent backup log
  ssdvault restic    <vault> <args...>       run restic on a vault's repository
                                             (snapshots, ls, diff, restore, ...)
  ssdvault stop                              abort the running backups
  ssdvault uninstall                         remove the tasks; repositories are kept
'@ | Write-Host
}

# ---------------------------------------------------------------- small helpers

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Write-Host $line
    try {
        New-Dir $LogDir
        $file = Join-Path $LogDir ('ssdvault-{0:yyyy-MM}.log' -f (Get-Date))
        [IO.File]::AppendAllText($file, $line + "`r`n", $Utf8)
    } catch { }
}

function New-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path -Force) }
}

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Format-Unix($Seconds) {
    if (-not $Seconds) { return 'never' }
    [DateTimeOffset]::FromUnixTimeSeconds([long]$Seconds).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
}

function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
function Write-Json([string]$Path, $Object) { [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 4), $Utf8) }
function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8) }

function New-RandomBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return , $bytes
}

function Get-Opt([string[]]$Argv, [string]$Name, [string]$Default = '') {
    for ($i = 0; $i -lt $Argv.Count - 1; $i++) {
        if ($Argv[$i] -eq "-$Name") { return $Argv[$i + 1] }
    }
    return $Default
}

function Get-Positional([string[]]$Argv) {
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        if ($Argv[$i].StartsWith('-')) { $i++; continue }
        return $Argv[$i]
    }
    return ''
}

function Format-Name([string]$Name) {
    $n = ([string]$Name -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-'
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
    $n = $n.Trim('.', '-')
    if (-not $n) { $n = 'ssd' }
    return $n
}

function Resolve-Root([string]$Path) {
    if (-not $Path) { throw 'missing drive, e.g. E:' }
    if ($Path -match '^[A-Za-z]:?\\?$') { $Path = $Path.Substring(0, 1).ToUpperInvariant() + ':\' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Path is not a drive or folder" }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# The id file comes from removable media, so it is validated strictly before it is used in paths.
function Read-VaultId([string]$Root) {
    try {
        $file = Get-Item -LiteralPath (Join-Path $Root "$MarkerDir\id") -Force -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -gt 200) { return $null }
        $id = [IO.File]::ReadAllText($file.FullName).Trim().ToLowerInvariant()
        if ($id -match '^[0-9a-f]{64}$') { return $id }
    } catch { }
    return $null
}

function Get-VaultDrives {
    $found = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -eq [IO.DriveType]::Network -or $d.DriveType -eq [IO.DriveType]::CDRom) { continue }
            if (-not $d.IsReady) { continue }
            $id = Read-VaultId $d.RootDirectory.FullName
            if ($id) { $found += [pscustomobject]@{ Root = $d.RootDirectory.FullName; Id = $id } }
        } catch { }
    }
    return $found
}

# ---------------------------------------------------------------- config, vaults, state

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfFile)) { throw 'SSDVault is not installed on this PC. Run: ssdvault install' }
    $c = Read-Json $ConfFile
    $script:Restic = $c.ResticPath
    $script:RepoRoot = $c.RepoRoot
    if (-not (Test-Path -LiteralPath $script:Restic)) { throw "restic not found at $($script:Restic). Run: ssdvault install -ResticPath <path>" }
}

function Get-Vault([string]$Id) {
    $f = Join-Path $VaultDir "$Id.json"
    if (Test-Path -LiteralPath $f) { return Read-Json $f }
    return $null
}

function Get-Vaults {
    if (-not (Test-Path -LiteralPath $VaultDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $VaultDir -Filter '*.json' | ForEach-Object { Read-Json $_.FullName })
}

function Resolve-Vault([string]$Key) {
    $hits = @(Get-Vaults | Where-Object { $_.Name -eq $Key -or ($Key.Length -ge 4 -and $_.Id.StartsWith($Key.ToLowerInvariant())) })
    if ($hits.Count -eq 0) { throw "no vault called '$Key' on this PC (see: ssdvault status)" }
    if ($hits.Count -gt 1) { throw "'$Key' matches more than one vault; use more of the id" }
    return $hits[0]
}

function Use-Vault($Vault) {
    $env:RESTIC_REPOSITORY = $Vault.Repo
    $env:RESTIC_PASSWORD_FILE = $Vault.PasswordFile
}

function Get-State([string]$Id) {
    $s = [ordered]@{ LastAttempt = $null; LastSuccess = $null; LastResult = $null; LastSnapshot = $null
                     LastError = $null; LastPrune = $null; LastCheck = $null; LastCheckResult = $null }
    $f = Join-Path $StateDir "$Id.json"
    if (Test-Path -LiteralPath $f) {
        $j = Read-Json $f
        foreach ($k in @($s.Keys)) { if ($j.PSObject.Properties[$k]) { $s[$k] = $j.$k } }
    }
    return $s
}

function Save-State([string]$Id, $State) { New-Dir $StateDir; Write-Json (Join-Path $StateDir "$Id.json") $State }

# ---------------------------------------------------------------- restic + notifications

function Invoke-Restic([string[]]$ResticArgs, [switch]$Quiet) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # restic reports progress and warnings on stderr
    try {
        & $script:Restic @ResticArgs 2>&1 | ForEach-Object {
            $l = "$_"
            $lines.Add($l)
            if (-not $Quiet) { Write-Log "  $l" }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
    return [pscustomobject]@{ Code = $code; Output = $lines }
}

function Test-ResticVersion([int]$Major, [int]$Minor) {
    if (-not $script:ResticVersion) {
        $v = (Invoke-Restic @('version') -Quiet).Output | Select-Object -First 1
        if ($v -match '^restic (\d+)\.(\d+)') { $script:ResticVersion = [version]"$($Matches[1]).$($Matches[2])" }
        else { $script:ResticVersion = [version]'0.0' }
    }
    return $script:ResticVersion -ge [version]"$Major.$Minor"
}

function Show-Toast([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        Write-Log "(notification not shown: $($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------- backup

function Invoke-Maintenance($Vault, $State) {
    $now = Get-UnixNow
    if (-not $State.LastPrune -or ($now - [long]$State.LastPrune) -ge $PruneEvery) {
        Write-Log "$($Vault.Name): applying the retention policy"
        $r = Invoke-Restic (@('forget', '--tag', 'ssdvault', '--group-by', 'host', '--prune') + $Keep) -Quiet
        if ($r.Code -eq 0) { $State.LastPrune = $now }
        else {
            $r.Output | Select-Object -Last 5 | ForEach-Object { Write-Log "  $_" }
            Show-Toast "SSDVault: $($Vault.Name)" 'Removing old snapshots failed. See: ssdvault log'
        }
    }
    if (-not $State.LastCheck -or ($now - [long]$State.LastCheck) -ge $CheckEvery) {
        Write-Log "$($Vault.Name): verifying the repository (structure + 2% of the data)"
        $State.LastCheck = $now
        $r = Invoke-Restic @('check', '--read-data-subset', '2%') -Quiet
        if ($r.Code -eq 0) { $State.LastCheckResult = 'ok' }
        else {
            $State.LastCheckResult = 'failed'
            $r.Output | ForEach-Object { Write-Log "  $_" }
            Show-Toast "SSDVault: $($Vault.Name)" "Repository check FAILED: the backups on this PC may be damaged. Run: ssdvault restic $($Vault.Name) check"
        }
    }
    Save-State $Vault.Id $State
}

function Backup-Vault($Drive, [string]$Reason) {
    $id = $Drive.Id
    $root = $Drive.Root
    $vault = Get-Vault $id
    if (-not $vault) {
        Write-Log "Found an SSDVault drive at $root (id $($id.Substring(0, 8))) that is not registered on this PC. Run: ssdvault register $root"
        return
    }
    $name = $vault.Name
    New-Dir $StateDir
    try { $lock = [IO.File]::Open((Join-Path $StateDir "$id.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { Write-Log "${name}: a backup is already running"; return }

    try {
        $state = Get-State $id
        $now = Get-UnixNow
        if ($state.LastSuccess -and ($now - [long]$state.LastSuccess) -lt $MinInterval[$Reason]) {
            Write-Log "${name}: last backup $($now - [long]$state.LastSuccess)s ago, skipping"
            return
        }

        Use-Vault $vault
        if ($Reason -eq 'plug') { Show-Toast "SSDVault: $name" "Backup started. Wait for 'done' before unplugging." }
        [void](Invoke-Restic @('unlock') -Quiet)

        $a = @('backup', $root, '--tag', 'ssdvault', '--exclude-caches', '--exclude-if-present', '.nobackup',
               '--ignore-inode', '--exclude', "$MarkerDir/history.log")
        $excludes = Join-Path $root "$MarkerDir\excludes.txt"
        if (Test-Path -LiteralPath $excludes) { $a += @('--exclude-file', $excludes) }
        if (Test-ResticVersion 0 17) { $a += '--skip-if-unchanged' }

        Write-Log "${name}: backing up $root -> $($vault.Repo)"
        $t0 = Get-UnixNow
        $r = Invoke-Restic $a
        $secs = (Get-UnixNow) - $t0
        $snap = $null
        foreach ($l in $r.Output) { if ($l -match '^snapshot ([0-9a-f]{8}) saved') { $snap = $Matches[1] } }

        if ($r.Code -eq 0) { $result = 'ok' }
        elseif ($r.Code -eq 3) { if (Read-VaultId $root) { $result = 'warnings' } else { $result = 'interrupted' } }
        else { $result = 'failed' }
        if ($result -eq 'interrupted' -and $snap) {
            Write-Log "${name}: the drive went away during the backup; discarding incomplete snapshot $snap"
            [void](Invoke-Restic @('forget', $snap) -Quiet)
            $snap = $null
        }

        $state.LastAttempt = $t0
        $state.LastResult = $result
        if ($result -eq 'ok' -or $result -eq 'warnings') {
            $state.LastSuccess = $t0
            $state.LastSnapshot = if ($snap) { $snap } else { 'unchanged' }
            $state.LastError = $null
        } else {
            $tail = @($r.Output | Select-Object -Last 3) -join ' '
            if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) }
            $state.LastError = $tail
        }
        Save-State $id $state

        if ($result -ne 'interrupted') {
            try {
                $entry = "{0}`t{1}`twindows`t{2}`t{3}`t{4}s`n" -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'), $env:COMPUTERNAME, $result, $(if ($snap) { $snap } else { '-' }), $secs
                [IO.File]::AppendAllText((Join-Path $root "$MarkerDir\history.log"), $entry, $Utf8)
            } catch { }
        }

        $what = if ($snap) { "snapshot $snap" } elseif ($r.Code -eq 0) { 'nothing changed' } else { 'no snapshot' }
        switch ($result) {
            'ok'          { if ($Reason -eq 'plug') { Show-Toast "SSDVault: $name" "Backup done in ${secs}s ($what)." } }
            'warnings'    { Show-Toast "SSDVault: $name" 'Backup done, but some files could not be read. See: ssdvault log' }
            'interrupted' { Show-Toast "SSDVault: $name" 'The drive was removed during the backup; that run was discarded.' }
            'failed'      { Show-Toast "SSDVault: $name" "Backup FAILED (restic exit $($r.Code)). See: ssdvault log" }
        }
        Write-Log "${name}: $result in ${secs}s ($what)"

        if ($result -eq 'ok' -or $result -eq 'warnings') { Invoke-Maintenance $vault $state }
    } finally {
        $lock.Dispose()
    }
}

function Invoke-Run([string]$Reason, [string]$Path) {
    if ($MinInterval.Keys -notcontains $Reason) { throw "bad -Reason: $Reason" }
    Get-Config
    if ($Path) {
        $root = Resolve-Root $Path
        $id = Read-VaultId $root
        if (-not $id) { throw "no SSDVault marker in $root" }
        Backup-Vault ([pscustomobject]@{ Root = $root; Id = $id }) $Reason
        return
    }
    # The plug trigger fires as soon as the disk shows up, before Windows has mounted the
    # volume, and also on removals; poll for a while and back up whatever vault appears.
    $deadline = (Get-Date).AddSeconds($(if ($Reason -eq 'plug') { $PlugWait } else { 0 }))
    $seen = @{}
    while ($true) {
        foreach ($d in @(Get-VaultDrives)) {
            if ($seen.ContainsKey($d.Id)) { continue }
            $seen[$d.Id] = $true
            Backup-Vault $d $Reason
        }
        if ($seen.Count -gt 0 -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 3
    }
    if ($seen.Count -eq 0 -and $Reason -eq 'manual') { Write-Log 'No SSDVault drive is connected.' }
    if ($seen.Count -eq 0 -and $Reason -eq 'plug') { Write-Log "Disk event: no SSDVault drive appeared within ${PlugWait}s." }
}

# ---------------------------------------------------------------- register

function Register-Vault([string]$Target, [string]$Name) {
    Get-Config
    $root = Resolve-Root $Target
    $mdir = Join-Path $root $MarkerDir
    New-Dir $mdir
    try { (Get-Item -LiteralPath $mdir -Force).Attributes = 'Directory, Hidden' } catch { }

    $id = Read-VaultId $root
    if (-not $id) {
        if (Test-Path -LiteralPath (Join-Path $mdir 'id')) { throw "$mdir\id exists but is not a valid SSDVault id; refusing to overwrite it" }
        $id = -join ((New-RandomBytes 32) | ForEach-Object { $_.ToString('x2') })
        Write-Text (Join-Path $mdir 'id') "$id`n"
        Write-Log "New vault id written to the drive: $id"
    }
    $nameFile = Join-Path $mdir 'name'
    if ($Name) {
        $Name = Format-Name $Name
        Write-Text $nameFile "$Name`n"
    } elseif (Test-Path -LiteralPath $nameFile) {
        $Name = Format-Name (([IO.File]::ReadAllText($nameFile) -split "`n")[0].Trim())
    } else {
        $label = ''
        if ($root.Length -eq 3) { try { $label = (New-Object IO.DriveInfo $root).VolumeLabel } catch { } }
        else { $label = Split-Path -Leaf $root }
        $Name = Format-Name $label
        Write-Text $nameFile "$Name`n"
    }
    $f = Join-Path $mdir 'excludes.txt'
    if (-not (Test-Path -LiteralPath $f)) { Write-Text $f ($DefaultExcludes -replace "`r`n", "`n") }
    $f = Join-Path $mdir 'README.txt'
    if (-not (Test-Path -LiteralPath $f)) { Write-Text $f $DriveReadme }

    $existing = Get-Vault $id
    if ($existing) { Write-Log "'$($existing.Name)' is already registered on this PC (repository $($existing.Repo))"; return }

    New-Dir $VaultDir; New-Dir $KeyDir; New-Dir $StateDir; New-Dir $script:RepoRoot
    $repo = Join-Path $script:RepoRoot ('{0}-{1}' -f $Name, $id.Substring(0, 8))
    $key = Join-Path $KeyDir "$id.pass"
    $vault = [pscustomobject]@{ Id = $id; Name = $Name; Repo = $repo; PasswordFile = $key }
    if (Test-Path -LiteralPath (Join-Path $repo 'config')) {
        if (-not (Test-Path -LiteralPath $key)) { throw "$repo already exists but its password file is missing; put the password in $key and register again" }
        Write-Log "Reusing the existing repository $repo"
    } else {
        if (-not (Test-Path -LiteralPath $key)) { Write-Text $key ([Convert]::ToBase64String((New-RandomBytes 32))) }
        Use-Vault $vault
        $r = Invoke-Restic @('init')
        if ($r.Code -ne 0) { throw "restic init failed (exit $($r.Code))" }
    }
    Write-Json (Join-Path $VaultDir "$id.json") $vault
    Write-Log "Registered '$Name' (id $($id.Substring(0, 8))) -> $repo"
    Write-Host ''
    Write-Host "Repository password: $key"
    Write-Host 'Save it in your password manager: without it, the backups on this PC cannot be read.'
    Write-Host 'First backup now:    ssdvault run'
}

# ---------------------------------------------------------------- status, stop, restic

function Show-Status {
    Get-Config
    $present = @{}
    foreach ($d in @(Get-VaultDrives)) { $present[$d.Id] = $d.Root }
    $vaults = @(Get-Vaults)
    if ($vaults.Count -eq 0) { Write-Host 'No vault registered on this PC. Plug the drive in and run: ssdvault register E:'; return }
    foreach ($v in $vaults) {
        $st = Get-State $v.Id
        $bytes = (Get-ChildItem -LiteralPath $v.Repo -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Write-Host ("== {0} ({1})" -f $v.Name, $v.Id.Substring(0, 8))
        Write-Host ("   repository : {0} ({1:N1} GB)" -f $v.Repo, ($bytes / 1GB))
        Write-Host ("   last backup: {0} ({1})" -f (Format-Unix $st.LastSuccess), $st.LastSnapshot)
        Write-Host ("   last result: {0} {1}" -f $st.LastResult, $st.LastError)
        if ($st.LastCheck) { Write-Host ("   last check : {0} {1}" -f (Format-Unix $st.LastCheck), $st.LastCheckResult) }
        if ($present.ContainsKey($v.Id)) {
            Write-Host "   drive      : connected at $($present[$v.Id])"
            $hist = Join-Path $present[$v.Id] "$MarkerDir\history.log"
            if (Test-Path -LiteralPath $hist) {
                Write-Host "   latest backup of this drive on each PC (from the drive's history.log):"
                $latest = @{}
                foreach ($line in [IO.File]::ReadAllLines($hist)) {
                    $f = ($line -replace '[^\t\x20-\x7e]', '?') -split "`t"
                    if ($f.Count -ge 5) { $latest[$f[1]] = $f }
                }
                foreach ($h in ($latest.Keys | Sort-Object)) {
                    $f = $latest[$h]
                    Write-Host ("     {0,-25} {1,-20} {2,-8} {3,-11} {4}" -f $f[0], $f[1], $f[2], $f[3], $f[4])
                }
            }
        } else {
            Write-Host '   drive      : not connected'
        }
    }
}

function Stop-Backups {
    $runs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
              Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ssdvault\.ps1' -and $_.CommandLine -match '\srun(\s|$)' })
    $ids = @($runs | ForEach-Object { $_.ProcessId })
    $children = @(Get-CimInstance Win32_Process -Filter "Name='restic.exe'" | Where-Object { $ids -contains $_.ParentProcessId })
    foreach ($p in $runs + $children) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }
    Write-Log ("Stopped {0} running backup(s)." -f $runs.Count)
}

# Points the restic environment at a vault and returns the remaining (restic) arguments.
# The caller runs restic itself, so its output streams straight to the console.
function Initialize-ResticFor([string[]]$Argv) {
    if ($Argv.Count -lt 1) { throw 'usage: ssdvault restic <vault> <restic arguments...>' }
    Get-Config
    Use-Vault (Resolve-Vault $Argv[0])
    if ($Argv.Count -gt 1) { return $Argv[1..($Argv.Count - 1)] }
}

# ---------------------------------------------------------------- install / uninstall

function Find-Restic {
    $c = Get-Command restic -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\restic.exe'
    if (Test-Path -LiteralPath $link) { return $link }
    $pkg = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Filter 'restic*.exe' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

function Register-Tasks {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $BinDir 'ssdvault.ps1')`" run -Reason"
    $query = '<QueryList><Query Id="0" Path="Microsoft-Windows-Partition/Diagnostic"><Select Path="Microsoft-Windows-Partition/Diagnostic">*[System[(EventID=1006)]]</Select></Query></QueryList>'
    $tasks = @(
        @{ Name = 'Plug'; Reason = 'plug'; Desc = 'SSDVault: back up an SSDVault drive as soon as it is plugged in.'
           Trigger = "<EventTrigger><Enabled>true</Enabled><Subscription>$([Security.SecurityElement]::Escape($query))</Subscription><Delay>PT5S</Delay></EventTrigger>" },
        @{ Name = 'Periodic'; Reason = 'timer'; Desc = 'SSDVault: back up connected SSDVault drives every 30 minutes.'
           Trigger = "<TimeTrigger><Enabled>true</Enabled><StartBoundary>$((Get-Date).Date.ToString('s'))</StartBoundary><Repetition><Interval>PT30M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger>" }
    )
    foreach ($t in $tasks) {
        # conhost --headless runs the console app with no window at all; -WindowStyle Hidden
        # still flashes one, and pops up Windows Terminal when that is the default console.
        if ([Environment]::OSVersion.Version.Build -ge 19041 -and (Test-Path -LiteralPath $conhost)) {
            $exe = $conhost; $exeArgs = "--headless `"$ps`" $psArgs $($t.Reason)"
        } else {
            $exe = $ps; $exeArgs = "-WindowStyle Hidden $psArgs $($t.Reason)"
        }
        $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$([Security.SecurityElement]::Escape($t.Desc))</Description></RegistrationInfo>
  <Triggers>$($t.Trigger)</Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$([Security.SecurityElement]::Escape($exe))</Command>
      <Arguments>$([Security.SecurityElement]::Escape($exeArgs))</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        [void](Register-ScheduledTask -TaskName $t.Name -TaskPath $TaskFolder -Xml $xml -Force)
    }
}

function Install-SSDVault([string]$RepoRoot, [string]$ResticPath) {
    if (-not $ResticPath) { $ResticPath = Find-Restic }
    if (-not $ResticPath -or -not (Test-Path -LiteralPath $ResticPath)) {
        throw 'restic not found. Install it with "winget install -e --id restic.restic", open a new terminal and run install again (or pass -ResticPath).'
    }
    if (-not $RepoRoot) {
        $RepoRoot = Join-Path $AppDir 'repos'
        if (Test-Path -LiteralPath $ConfFile) { $RepoRoot = (Read-Json $ConfFile).RepoRoot }
    }
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    foreach ($d in @($AppDir, $BinDir, $VaultDir, $KeyDir, $StateDir, $LogDir, $RepoRoot)) { New-Dir $d }
    try { (Get-Item -LiteralPath $AppDir -Force).Attributes = 'Directory, Hidden' } catch { }

    $target = Join-Path $BinDir 'ssdvault.ps1'
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
    Write-Text (Join-Path $BinDir 'ssdvault.cmd') "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ssdvault.ps1`" %*`r`n"
    Write-Json $ConfFile ([pscustomobject]@{ ResticPath = (Resolve-Path -LiteralPath $ResticPath).ProviderPath; RepoRoot = $RepoRoot })

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if (($userPath -split ';') -notcontains $BinDir) {
        # Keep a trailing separator where it was, so uninstall restores the exact old value.
        if (-not $userPath) { $newPath = $BinDir }
        elseif ($userPath.EndsWith(';')) { $newPath = "$userPath$BinDir;" }
        else { $newPath = "$userPath;$BinDir" }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Log "Added $BinDir to your PATH (open a new terminal to use 'ssdvault')."
    }
    Register-Tasks
    Get-Config
    [void](Test-ResticVersion 0 0)
    Write-Log "Installed: $target, repositories in $RepoRoot, restic $($script:ResticVersion)"
    Write-Host 'Next: plug the drive in and run: ssdvault register E:   (use its drive letter)'
}

function Uninstall-SSDVault {
    foreach ($n in @('Plug', 'Periodic')) {
        try { Unregister-ScheduledTask -TaskName $n -TaskPath $TaskFolder -Confirm:$false -ErrorAction Stop } catch { }
    }
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $svc.GetFolder('\').DeleteFolder('SSDVault', 0)
    } catch { }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { $_ -ne $BinDir })
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    }
    Write-Log "Tasks and PATH entry removed. Kept: $AppDir (repository passwords in $KeyDir, logs) and the repositories."
    Write-Log "Delete $BinDir by hand if you no longer need the program."
}

# ---------------------------------------------------------------- main

try { [Console]::OutputEncoding = $Utf8 } catch { }   # restic prints UTF-8 file names

$argv = @($args | ForEach-Object { [string]$_ })
$cmd = if ($argv.Count -gt 0) { $argv[0].ToLowerInvariant() } else { 'help' }
$rest = @()
if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

try {
    switch ($cmd) {
        'install'   { Install-SSDVault (Get-Opt $rest 'RepoRoot') (Get-Opt $rest 'ResticPath') }
        'register'  { Register-Vault (Get-Positional $rest) (Get-Opt $rest 'Name') }
        'run'       { Invoke-Run (Get-Opt $rest 'Reason' 'manual') (Get-Opt $rest 'Path') }
        'status'    { Show-Status }
        'log'       { Get-ChildItem -LiteralPath $LogDir -Filter '*.log' | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 80 -Encoding UTF8 } }
        'restic'    {
            $ra = @(Initialize-ResticFor $rest)
            $ErrorActionPreference = 'Continue'
            & $script:Restic @ra
            exit $LASTEXITCODE
        }
        'stop'      { Stop-Backups }
        'uninstall' { Uninstall-SSDVault }
        default     { Show-Help }
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if ($cmd -eq 'run') { Show-Toast 'SSDVault' "Backup error: $($_.Exception.Message)" }
    exit 1
}
