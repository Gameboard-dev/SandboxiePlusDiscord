<#
.SYNOPSIS
    Stamps an AppUserModelID (AUMID) onto the "Discord" shortcut so its
    taskbar button merges with the sandboxed Discord window instead of sitting
    beside it as a duplicate.

.DESCRIPTION
    The taskbar identifies an application by AUMID. A shortcut with no AUMID of
    its own is identified by its target -- here launch-discord.vbs, i.e.
    wscript.exe -- which has nothing in common with the Discord window the
    launch eventually produces, so Windows draws two buttons. A shortcut that
    inherited Discord's own "com.squirrel.Discord.Discord" is no better: the
    sandboxed window does not use that AUMID.

    Sandboxie-Plus rewrites the AUMID of the processes it hosts to

        Sandbox.<BoxName>.<original AUMID, dots replaced by underscores>

    Writing that same string into the shortcut's property store
    (System.AppUserModel.ID) tells the shell the two belong together, and the
    launched window docks into the pinned button.

    With no -Aumid, the value is discovered from a running sandboxed window via
    get-window-aumid.ps1, so start Discord from the box before running this.

    A pinned shortcut is a private copy under User Pinned\TaskBar, so it is
    patched too; the taskbar only re-reads it after Explorer restarts.

.PARAMETER Aumid
    The AUMID to write. Defaults to that of a running sandboxed Discord window.

.PARAMETER Path
    Shortcuts to patch. Defaults to every copy of ShortcutName found in the
    repository root, on the Desktop, in the Start Menu, and pinned to the taskbar.

.PARAMETER ShortcutName
    Filename used for the default search. Defaults to "Discord.lnk".

.PARAMETER RestartExplorer
    Restart Explorer afterwards so the taskbar picks up a patched pin.

.EXAMPLE
    .\set-shortcut-aumid.ps1 -WhatIf

.EXAMPLE
    .\set-shortcut-aumid.ps1 -Aumid 'Sandbox.Discord.com_squirrel_Discord_Discord' -RestartExplorer

.NOTES
    Run as the user who owns the shortcut. Unpinning and re-pinning after the
    stamp is the most reliable way to refresh a pin that Windows has cached.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $Aumid,
    [string[]] $Path,
    [string]   $ShortcutName = 'Discord.lnk',
    [switch]   $RestartExplorer
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not ('Aum.ShortcutAumid' -as [type])) {
    Add-Type -Path (Join-Path $here 'AumidInterop.cs')
}

# --- Work out which AUMID to stamp --------------------------------------------
if (-not $Aumid) {
    $probe = Join-Path $here 'get-window-aumid.ps1'
    if (-not (Test-Path $probe)) {
        throw "No -Aumid given and $probe is missing. Pass -Aumid explicitly."
    }

    $windows = @(& $probe -ProcessName 'Discord')
    $Aumid = ($windows | Where-Object { $_.Aumid } | Select-Object -First 1).Aumid

    if (-not $Aumid) {
        throw "No AUMID found on any Discord window. Launch Discord inside the box first, or pass -Aumid explicitly."
    }
    Write-Host "Discovered AUMID from a running window: $Aumid" -ForegroundColor Cyan
}

# --- Work out which shortcuts to patch ----------------------------------------
if (-not $Path) {
    $searchDirs = @(
        (Split-Path -Parent $here)                                                  # repository root
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('CommonDesktopDirectory')
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    )

    $Path = $searchDirs |
        Where-Object { $_ -and (Test-Path $_) } |
        ForEach-Object { Join-Path $_ $ShortcutName } |
        Where-Object { Test-Path $_ } |
        Select-Object -Unique
}

if (-not $Path) {
    throw "No shortcut named '$ShortcutName' found. Pass -Path explicitly."
}

# --- Stamp --------------------------------------------------------------------
foreach ($lnk in $Path) {
    $full = (Resolve-Path -LiteralPath $lnk).Path
    $before = [Aum.ShortcutAumid]::Read($full)

    if ($before -eq $Aumid) {
        Write-Host "unchanged  $full (already $Aumid)" -ForegroundColor DarkGray
        continue
    }

    if ($PSCmdlet.ShouldProcess($full, "Set System.AppUserModel.ID to '$Aumid'")) {
        [Aum.ShortcutAumid]::Write($full, $Aumid)

        $after = [Aum.ShortcutAumid]::Read($full)
        if ($after -ne $Aumid) {
            throw "Wrote '$Aumid' to $full but it reads back as '$after'."
        }

        $wasText = if ($before) { "was '$before'" } else { 'was unset' }
        Write-Host "stamped    $full ($wasText)" -ForegroundColor Green
    }
}

# --- Refresh the taskbar ------------------------------------------------------
# Explorer caches pinned shortcuts, so a patched pin keeps its old identity
# until Explorer is restarted -- or the shortcut is unpinned and re-pinned.
if ($RestartExplorer) {
    if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart to refresh the taskbar')) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Write-Host 'Explorer restarted.' -ForegroundColor Green
    }
} else {
    Write-Host ''
    Write-Host 'Restart Explorer (or re-run with -RestartExplorer) for a pinned copy to take effect.' -ForegroundColor Yellow
}
