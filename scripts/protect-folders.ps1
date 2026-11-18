<#
.SYNOPSIS
    Makes the launcher scripts and Sandboxie-Plus's program files read-only for
    your normal account. Run once, as administrator, after cloning or updating.

.DESCRIPTION
    Why: the launcher hands the box passphrase to SbieDll.dll, and
    clean-discord.vbs runs INSIDE the box, next to the session token. If a
    program running as you (no admin needed) could edit either, or replace
    Sandboxie's Start.exe/SbieDll.dll, it would get the passphrase on your next
    Windows Hello approval, or copy the token out through scripts\shared.

    What it does, under -Root (default: the folder that holds this repo):
      1. Administrators own everything, so your account can't re-grant itself
         rights (an owner can always rewrite an ACL).
      2. -Root and everything in it: Administrators and SYSTEM full control,
         Users read and execute. Nothing in it can be renamed or replaced.
      3. Re-opened for Authenticated Users (Modify, which can't delete the
         folder's children or change permissions):
           - the repo folder, so git keeps working;
           - scripts\shared, the box's two-way folder (log, file transfer).
         scripts\ itself stays read-only.
    Sandboxie-Plus's install folder is included when it sits under -Root, as
    with a portable install. Under Program Files it is already admin-only.

    Updating scripts\ later (git pull, edits) needs an elevated prompt.

    Undo:  icacls <Root> /inheritance:e   then   icacls <Root> /reset /T /C
#>
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this from an administrator PowerShell: it changes folder ownership and permissions."
}

$Root    = (Resolve-Path $Root).Path.TrimEnd('\')
$repo    = Split-Path $PSScriptRoot -Parent
$scripts = $PSScriptRoot
$shared  = Join-Path $PSScriptRoot "shared"

# Refuse folders whose permissions Windows or the user profile depend on.
$refuse = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE) |
    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
if ($Root -match '^[A-Za-z]:$') {
    throw "-Root is a drive root ($Root\). Point it at the folder that holds the repo."
}
foreach ($r in $refuse) {
    if ($Root -ieq $r -or $Root.StartsWith("$r\", 'OrdinalIgnoreCase') -or $r.StartsWith("$Root\", 'OrdinalIgnoreCase')) {
        throw "-Root ($Root) overlaps $r. Move the repo (and a portable Sandboxie) to a folder of their own, such as D:\Sandboxie, and run again."
    }
}
if (-not $repo.StartsWith("$Root\", 'OrdinalIgnoreCase') -and $repo -ine $Root) {
    throw "The repo ($repo) is not inside -Root ($Root)."
}

# Report where Sandboxie lives, so it's clear whether it's covered.
$svc = Get-CimInstance Win32_Service -Filter "Name='SbieSvc'" -ErrorAction SilentlyContinue
$sbieDir = if ($svc) { Split-Path ($svc.PathName.Trim('"') -replace '"\s.*$', '') -Parent } else { $null }

function Invoke-Icacls {
    # Argument array, not a command string: paths are passed as data.
    & icacls.exe @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls $($args -join ' ') failed with exit code $LASTEXITCODE." }
}

$admins = '*S-1-5-32-544'; $system = '*S-1-5-18'; $users = '*S-1-5-32-545'; $authUsers = '*S-1-5-11'

Write-Host "Protecting $Root"
Invoke-Icacls $Root /setowner $admins /T /C /Q
Invoke-Icacls $Root /inheritance:r /grant:r "${admins}:(OI)(CI)F" "${system}:(OI)(CI)F" "${users}:(OI)(CI)RX" /C /Q
Invoke-Icacls "$Root\*" /reset /T /C /Q

Write-Host "Re-opening $repo for git (Modify)"
Invoke-Icacls $repo /grant:r "${authUsers}:(OI)(CI)M" /C /Q

Write-Host "Locking $scripts (read-only)"
Invoke-Icacls $scripts /inheritance:r /grant:r "${admins}:(OI)(CI)F" "${system}:(OI)(CI)F" "${users}:(OI)(CI)RX" /C /Q
Invoke-Icacls "$scripts\*" /reset /T /C /Q

Write-Host "Re-opening $shared (Modify)"
Invoke-Icacls $shared /grant:r "${authUsers}:(OI)(CI)M" /C /Q

Write-Host ""
if ($sbieDir -and $sbieDir.StartsWith("$Root\", 'OrdinalIgnoreCase')) {
    Write-Host "Sandboxie-Plus ($sbieDir) is inside $Root and now read-only." -ForegroundColor Green
}
elseif ($sbieDir) {
    Write-Host "Sandboxie-Plus is at $sbieDir, outside $Root. Check that only administrators can write there." -ForegroundColor Yellow
}
Write-Host "Done. Your account can no longer change $scripts or anything else in $Root outside the repo files and scripts\shared." -ForegroundColor Green
