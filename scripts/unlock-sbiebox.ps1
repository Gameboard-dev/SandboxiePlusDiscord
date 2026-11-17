<#
.SYNOPSIS
    Unlocks a TPM-sealed passphrase for a Sandboxie-Plus encrypted box, mounts
    that box, and launches a program inside it. Suitable as the target of a
    desktop shortcut or a login task.

.DESCRIPTION
    The box passphrase is encrypted during setup, using a non-exportable
    RSA key that lives inside the TPM chip (Microsoft Platform Crypto Provider).
    The ciphertext is stored on disk at %LOCALAPPDATA%\sbiebox.bin. This script:

.NOTES
    Run as the same user that created the key during setup. A key created by
    one user account cannot be opened by another.
#>

# ============================================================================
#  CONFIGURATION  -- edit these to match your install
# ============================================================================

# Full path to Sandboxie-Plus Start.exe.
# Leave as $null to auto-detect the standard install locations.
$StartExe = "D:\Sandboxie\Installer\SbiePlus_x64\Start.exe"

# Name of the encrypted box to mount.
$BoxName = "Discord"

# Name of the TPM key created at setup time (must match setup).
$KeyName = "SbieBoxKey"

# Path to the encrypted passphrase blob written at setup time.
$CipherFile = "$env:LOCALAPPDATA\sbiebox.bin"

# Use /mount_protected instead of /mount for SbieDrv root protection.
# Requires OpenFilePath paths configured on the box; leave $false unless set up.
$UseProtectedMount = $true

# Program to launch inside the box after mounting, plus its arguments.
$LaunchProgram = "$env:LOCALAPPDATA\Discord\Update.exe" # "C:\Sandbox\megatron\Discord\user\current\AppData\Local\Dorion\Dorion.exe"
$LaunchArgs    = @("--processStart", "Discord.exe")

# Set $false to only mount the box and not launch anything (e.g. for a pure
# login-time mount task rather than a launch shortcut).
$LaunchAfterMount = $true

# Free space inside the box before Discord starts. The box image has a fixed
# size, and Discord's updater keeps old versions, failed installs and downloads
# beside the new one until the image is full and the update loops on
# "retrying". clean-discord.vbs runs inside the box, only when nothing else runs
# there, and writes what it removed to $CleanLog. The log sits in
# scripts\shared\ because the box writes there straight to the host
# (OpenPipePath in Sandboxie.ini), so it stays readable after the box locks.
$CleanBeforeLaunch   = $true
$CleanScript         = Join-Path $PSScriptRoot "clean-discord.vbs"
$CleanLog            = Join-Path $PSScriptRoot "shared\cleanup.log"
$CleanTimeoutSeconds = 120

# Boxes mounted through Start.exe never lock on their own: SbieDll_Mount
# hard-codes auto_unmount = FALSE, so the box's "lock when all processes stop"
# option does not apply. When $true, the instance that mounted the box keeps
# running hidden and unmounts it once the box has been empty for two
# consecutive polls. The service refuses to unmount while anything is running.
$UnmountWhenEmpty = $true
$PollSeconds      = 5

# ============================================================================
#  END CONFIGURATION
# ============================================================================

# --- Resolve the Start.exe path ----------------------------------------------
# If not explicitly set above, probe the common install locations and take the
# first one that exists.
if (-not $StartExe) {
    $candidates = @(
        "$env:ProgramFiles\Sandboxie-Plus\Start.exe",
        "${env:ProgramFiles(x86)}\Sandboxie-Plus\Start.exe",
        "$env:ProgramW6432\Sandboxie-Plus\Start.exe"
    )
    $StartExe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

if (-not $StartExe -or -not (Test-Path $StartExe)) {
    throw "Start.exe not found. Set `$StartExe` in the configuration block to its full path."
}

# --- Helper: how many processes are running in the box? -----------------------
function Get-BoxProcessCount {
    param($StartExe, $BoxName)
    $out = (& $StartExe "/box:$BoxName" /listpids 2>$null | Out-String)
    # Write-Host "DEBUG /listpids raw output:" -ForegroundColor Cyan
    # Write-Host "----- begin -----"
    # Write-Host $out
    # Write-Host "----- end -----"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -match '\S' })  # force array
    if ($lines.Count -eq 0) {
        Write-Host "DEBUG parsed count: <null> (no output captured)" -ForegroundColor Yellow
        return $null                                
    }
    $count = [int]($lines[0].Trim())
    Write-Host "DEBUG parsed count: $count" -ForegroundColor Green
    return $count                                  
}

$procCount = Get-BoxProcessCount $StartExe $BoxName
$alreadyUp = ($null -ne $procCount -and $procCount -gt 0)
$mountedHere = $false

if (-not $alreadyUp) {

    # --- 1. Open the TPM-resident RSA key by its persistent name -------------
    $cng = [System.Security.Cryptography.CngKey]::Open(
        $KeyName,
        [System.Security.Cryptography.CngProvider]::new("Microsoft Platform Crypto Provider"))

    $rsa = [System.Security.Cryptography.RSACng]::new($cng)

    # --- 2. Read the encrypted passphrase blob from disk --------------------
    if (-not (Test-Path $CipherFile)) {
        throw "Cipher file not found at $CipherFile. Run setup first."
    }
    $cipher = [IO.File]::ReadAllBytes($CipherFile)

    # --- 3. Decrypt inside the TPM to recover the passphrase ------
    $plain = $null
    try {
        $plain = [Text.Encoding]::UTF8.GetString(
            $rsa.Decrypt($cipher, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))

        $mountFlag = if ($UseProtectedMount) { '/mount_protected' } else { '/mount' }
        # Start.exe is a GUI-subsystem program, so PowerShell only waits for it
        # (and only sets $LASTEXITCODE) when its output is piped. Without the
        # pipe, the launch below raced the mount and silently failed on the
        # first click, leaving a mounted-but-empty box for the second click.
        & $StartExe @("/box:$BoxName", "/key:$plain", $mountFlag) | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Mount failed (Start.exe exit code $LASTEXITCODE). Check the passphrase, box name, and that box-image encryption is actually enabled."
        }
        $mountedHere = $true
    }
    finally {
        $plain = $null
    }
}

# --- 5. Free space inside the box ------------------------------------------
# Only when the box was empty: deleting versions or caches under a running
# Discord would break it. wscript.exe rather than PowerShell because console
# programs can't start in the box on this Windows build (docs/TECHNICAL.md,
# "Known issues").
if (-not $alreadyUp -and $CleanBeforeLaunch) {
    if (Test-Path $CleanScript) {
        $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
        # Start-Process rather than & so the wait can time out: a hung cleanup
        # must not keep Discord from starting. Start.exe /wait returns when the
        # boxed wscript exits. Windows PowerShell joins -ArgumentList without
        # quoting, hence the explicit quotes around the paths.
        $cleanArgs = @("/box:$BoxName", "/wait", "`"$wscript`"", "//B", "//NoLogo",
                       "`"$CleanScript`"", "`"$CleanLog`"")
        $clean = Start-Process -FilePath $StartExe -ArgumentList $cleanArgs -PassThru -WindowStyle Hidden
        if (-not $clean.WaitForExit($CleanTimeoutSeconds * 1000)) {
            $msg = "{0:yyyy-MM-dd HH:mm:ss} WARN launcher: cleanup still running after $CleanTimeoutSeconds s; started Discord anyway" -f (Get-Date)
            try { Add-Content -Path $CleanLog -Value $msg -ErrorAction Stop } catch { }
        }
    }
    else {
        $msg = "{0:yyyy-MM-dd HH:mm:ss} WARN launcher: $CleanScript not found; skipped cleanup. Restore it from the repo or set `$CleanBeforeLaunch = `$false." -f (Get-Date)
        try { Set-Content -Path $CleanLog -Value $msg -ErrorAction Stop } catch { }
    }
}

# --- 6. Launch the program inside the box ------------------------------------
if ($LaunchAfterMount) {
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path $LaunchProgram) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (-not (Test-Path $LaunchProgram)) {
        throw "Launch program not found at $LaunchProgram after mount. Check the path and that the box mounted."
    }
    $launchCmd = @("/box:$BoxName", $LaunchProgram) + $LaunchArgs
    & $StartExe $launchCmd
}

# --- 7. Lock the box again once it is empty ----------------------------------
# Only the instance that mounted the box watches it; relaunches exit above.
# Two empty polls in a row ride out Discord's updater restarting the client,
# and the grace period covers the launch before any process has appeared.
if ($mountedHere -and $LaunchAfterMount -and $UnmountWhenEmpty) {
    $seenRunning = $false
    $emptyPolls  = 0
    $graceUntil  = (Get-Date).AddSeconds(60)

    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        $count = Get-BoxProcessCount $StartExe $BoxName

        if ($count -gt 0) {
            $seenRunning = $true
            $emptyPolls  = 0
            continue
        }
        if (-not $seenRunning -and (Get-Date) -lt $graceUntil) { continue }
        if (++$emptyPolls -ge 2) { break }
    }

    & $StartExe "/box:$BoxName" /unmount | Out-Null
}