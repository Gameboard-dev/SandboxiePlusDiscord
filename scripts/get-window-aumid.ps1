<#
.SYNOPSIS
    Reports the AppUserModelID (AUMID) that each visible top-level window
    presents to the Windows shell.

.DESCRIPTION
    The taskbar groups buttons by AUMID, not by executable path. Sandboxie-Plus
    rewrites the AUMID of every windowed process it hosts to

        Sandbox.<BoxName>.<original AUMID, dots replaced by underscores>

    so a sandboxed Discord reports "Sandbox.Discord.com_squirrel_Discord_Discord"
    rather than Discord's own "com.squirrel.Discord.Discord". A shortcut that
    launches the box therefore gets its own taskbar button unless the same
    rewritten AUMID is stamped onto the .lnk -- see set-shortcut-aumid.ps1.

    Run this while the sandboxed client is open to discover the exact string to
    stamp. Windows that inherit the shell default report no AUMID at all; those
    are omitted unless -All is given.

.PARAMETER ProcessName
    Only report windows owned by processes whose name matches this regex.

.PARAMETER TitleMatch
    Only report windows whose title matches this regex.

.PARAMETER All
    Include windows that carry no explicit AUMID.

.EXAMPLE
    .\get-window-aumid.ps1 -ProcessName Discord

.EXAMPLE
    .\get-window-aumid.ps1 -All | Format-Table ProcessName, Aumid, Title

.OUTPUTS
    Objects with Hwnd, ProcessId, ProcessName, Title and Aumid.
#>

[CmdletBinding()]
param(
    [string] $ProcessName,
    [string] $TitleMatch,
    [switch] $All
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not ('Aum.WindowAumid' -as [type])) {
    Add-Type -Path (Join-Path $here 'AumidInterop.cs')
}

# --- Walk every visible top-level window --------------------------------------
$found = New-Object System.Collections.ArrayList

$callback = [Aum.EnumWindowsProc] {
    param($hwnd, $lparam)

    if ([Aum.Native]::IsWindowVisible($hwnd)) {
        $procId = 0
        [void][Aum.Native]::GetWindowThreadProcessId($hwnd, [ref] $procId)

        $title = [Aum.Native]::GetWindowTitle($hwnd)
        if ($title) {
            [void] $found.Add([pscustomobject] @{
                Hwnd        = $hwnd
                ProcessId   = $procId
                ProcessName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
                Title       = $title
                Aumid       = [Aum.WindowAumid]::Read($hwnd)
            })
        }
    }
    return $true
}

[void][Aum.Native]::EnumWindows($callback, [IntPtr]::Zero)

# --- Filter and emit ----------------------------------------------------------
$results = $found
if (-not $All)    { $results = $results | Where-Object { $_.Aumid } }
if ($ProcessName) { $results = $results | Where-Object { $_.ProcessName -match $ProcessName } }
if ($TitleMatch)  { $results = $results | Where-Object { $_.Title -match $TitleMatch } }

$results
