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

# Mount with SbieDrv root protection (what Start.exe calls /mount_protected):
# while the box is unlocked, only programs inside the box, Sandboxie's service,
# csrss.exe and the Sandboxie-Plus window can open its files.
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
# "retrying". clean-discord.vbs runs inside the box just before Discord starts,
# only when nothing else runs there, and logs what it removed to $LaunchLog.
# It gets 120 s at most (CLEAN_TIMEOUT_S in start-in-box.vbs).
$CleanBeforeLaunch = $true
$CleanScript       = Join-Path $PSScriptRoot "clean-discord.vbs"

# One log per launch: the cleanup, each launcher step with timings, and the
# result of starting Discord. It sits in scripts\shared\ because the box writes
# there straight to the host (OpenPipePath in Sandboxie.ini), so it stays
# readable after the box locks.
$LaunchLog = Join-Path $PSScriptRoot "shared\launch.log"

# Boxes mounted through Start.exe never lock on their own: SbieDll_Mount
# hard-codes auto_unmount = FALSE, so the box's "lock when all processes stop"
# option does not apply. When $true, the instance that mounted the box keeps
# running hidden and unmounts it once the box has been empty for two
# consecutive polls. The service refuses to unmount while anything is running.
$UnmountWhenEmpty = $true
$PollSeconds      = 5

# How long after launch to wait for the first program to appear in the box
# before treating the start as failed and locking the box. A normal start
# takes seconds; the margin covers a slow first start after an update.
$LaunchGraceSeconds = 180

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

    # --- 3. Decrypt inside the TPM, then mount ------------------------------
    # The passphrase stays a byte[] that is zeroed in `finally`, and is handed
    # to SbieDll_Mount in-process (SbieMount.cs) instead of to Start.exe's
    # /key: argument, so it never appears on a command line. Never convert it
    # to a [string]: strings can't be wiped.
    $sbieDll = Join-Path (Split-Path $StartExe -Parent) "SbieDll.dll"
    if (-not (Test-Path $sbieDll)) {
        throw "SbieDll.dll not found at $sbieDll. Set `$StartExe to Sandboxie-Plus's Start.exe."
    }
    Add-Type -Path (Join-Path $PSScriptRoot "SbieMount.cs")

    $key = $null
    try {
        $key = $rsa.Decrypt($cipher, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        # Synchronous: returns once the service has mounted the image, so the
        # launch below can't race the mount.
        if (-not [SbieMount]::Mount($sbieDll, $BoxName, $key, $UseProtectedMount)) {
            throw "Mount failed: SbieDll_Mount returned FALSE for box '$BoxName'. Check Sandboxie-Plus's Messages panel (SBIE2243 means a wrong passphrase) and that box-image encryption is enabled."
        }
        $mountedHere = $true
    }
    finally {
        if ($key) { [Array]::Clear($key, 0, $key.Length) }
        $key = $null
    }
}

# Every step appends a timed line to one log, so a slow or failed start shows
# which step the time went to. A fresh unlock starts a fresh log.
function Write-LaunchLog([string]$Level, [string]$Message) {
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1} launcher: {2}" -f (Get-Date), $Level, $Message
    try { Add-Content -Path $LaunchLog -Value $line -ErrorAction Stop } catch { }
}
if ($mountedHere) {
    try { Set-Content -Path $LaunchLog -Value ("{0:yyyy-MM-dd HH:mm:ss} INFO launcher: unlocked box $BoxName" -f (Get-Date)) -ErrorAction Stop } catch { }
}

# --- 5 and 6. Clean up, then start Discord, from ONE boxed process -----------
# start-in-box.vbs runs the cleanup as a child, waits for it, then starts the
# program, all from a single wscript.exe in the box. Two separate boxed runs
# don't work: when the first exits, only SandboxieRpcSs's helpers are left, and
# SandboxieRpcSs then kills every program in the box (apps/com/RpcSs/linger.c,
# SbieDll_KillAll), including the launch that has just begun.
# The cleanup runs only when the box was empty: deleting versions or caches
# under a running Discord would break it.
# wscript.exe because console programs (PowerShell, cmd) can't start in the box
# on this Windows build (docs/TECHNICAL.md, "Known issues").
if ($LaunchAfterMount) {
    $startScript = Join-Path $PSScriptRoot "start-in-box.vbs"
    if (-not (Test-Path $startScript)) {
        Write-LaunchLog "WARN" "$startScript not found; can't start $LaunchProgram. Restore it from the repo."
        throw "$startScript not found. Restore it from the repo."
    }
    $clean = if (-not $alreadyUp -and $CleanBeforeLaunch) { $CleanScript } else { "-" }
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    # Windows PowerShell joins -ArgumentList without quoting, hence the quotes.
    $startArgs = @("/box:$BoxName", "`"$wscript`"", "//B", "//NoLogo", "`"$startScript`"",
                   "`"$LaunchLog`"", "`"$clean`"", "`"$LaunchProgram`"") + ($LaunchArgs | ForEach-Object { "`"$_`"" })
    Start-Process -FilePath $StartExe -ArgumentList $startArgs -WindowStyle Hidden
    $launchedAt = Get-Date
    Write-LaunchLog "INFO" ("asked the box to " + $(if ($clean -ne "-") { "clean up, then " } else { "" }) + "start $LaunchProgram")
}

# --- 7. Lock the box again once it is empty ----------------------------------
# Only the instance that mounted the box watches it; relaunches exit above.
# Two empty polls in a row ride out Discord's updater restarting the client,
# and the grace period covers the launch before any process has appeared.
if ($mountedHere -and $LaunchAfterMount -and $UnmountWhenEmpty) {
    $seenRunning = $false
    $emptyPolls  = 0
    $graceUntil  = (Get-Date).AddSeconds($LaunchGraceSeconds)

    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        $count = Get-BoxProcessCount $StartExe $BoxName

        if ($count -gt 0) {
            if (-not $seenRunning) {
                Write-LaunchLog "INFO" ("first program running in the box {0:N0} s after launch" -f ((Get-Date) - $launchedAt).TotalSeconds)
            }
            $seenRunning = $true
            $emptyPolls  = 0
            continue
        }
        if (-not $seenRunning -and (Get-Date) -lt $graceUntil) { continue }
        if (++$emptyPolls -ge 2) { break }
    }

    if ($seenRunning) {
        Write-LaunchLog "INFO" "box empty; locking it"
    }
    else {
        Write-LaunchLog "WARN" "nothing started in the box within $LaunchGraceSeconds s of launch; locking it. Check Sandboxie-Plus's Messages panel for SBIE codes, then click the shortcut again."
    }
    & $StartExe "/box:$BoxName" /unmount | Out-Null
}