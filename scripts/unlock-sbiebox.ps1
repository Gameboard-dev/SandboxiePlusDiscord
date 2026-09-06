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
$LaunchProgram = "C:\Sandbox\megatron\Discord\user\current\AppData\Local\Discord\Update.exe" # "C:\Sandbox\megatron\Discord\user\current\AppData\Local\Dorion\Dorion.exe"
$LaunchArgs    = @("--processStart", "Discord.exe")

# Set $false to only mount the box and not launch anything (e.g. for a pure
# login-time mount task rather than a launch shortcut).
$LaunchAfterMount = $true

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
        & $StartExe @("/box:$BoxName", "/key:$plain", $mountFlag)

        if ($LASTEXITCODE -ne 0) {
            throw "Mount failed (Start.exe exit code $LASTEXITCODE). Check the passphrase, box name, and that box-image encryption is actually enabled."
        }
    }
    finally {
        $plain = $null
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