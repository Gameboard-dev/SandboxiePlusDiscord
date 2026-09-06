<#
.SYNOPSIS
    One-time setup: seals a Sandboxie-Plus encrypted-box passphrase to the TPM.

.DESCRIPTION
    Counterpart to the unlock script. Run once, interactively, to establish the
    TPM-backed secret that unlock-sbiebox.ps1 later uses: a non-exportable RSA
    key is created inside the TPM (Microsoft Platform Crypto Provider), the box
    passphrase is prompted for, encrypted with that key, and only the
    ciphertext is written to %LOCALAPPDATA%\sbiebox.bin. From then on the
    passphrase can only be recovered by asking the TPM to decrypt that blob,
    which by default also requires Windows Hello (PIN/biometric) authentication;
    the plaintext is never written to disk.

.NOTES
    Run as the same user who will later run the unlock script -- a TPM key
    created by one account cannot be opened by another. Re-running after setup
    is already done fails at key creation by design; see "Resetting" below to
    start over. KeyName and CipherFile must match the unlock script.
#>

# Must match the unlock script.
$KeyName    = "SbieBoxKey"
$CipherFile = "$env:LOCALAPPDATA\sbiebox.bin"

# Require Windows Hello (PIN/biometric) on every decrypt, not just at setup.
# Without this, anything running as you can silently ask the TPM to decrypt
# the blob. Set $false to skip -- see "Resetting" below to change it later.
$RequireWindowsHello = $true

if ([System.Security.Cryptography.CngKey]::Exists(
        $KeyName,
        [System.Security.Cryptography.CngProvider]::new("Microsoft Platform Crypto Provider"))) {
    throw "TPM key '$KeyName' already exists. Setup has already been run. See 'Resetting' in this script's header to start over."
}

$keyParams = New-Object System.Security.Cryptography.CngKeyCreationParameters -Property @{
    Provider     = [System.Security.Cryptography.CngProvider]::new("Microsoft Platform Crypto Provider")
    KeyUsage     = [System.Security.Cryptography.CngKeyUsages]::Decryption
    ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::None
}

if ($RequireWindowsHello) {
    # ProtectKey makes NCrypt raise the Windows Hello / PIN credential prompt
    # on every use of the key, e.g. every RSACng.Decrypt() call in the unlock
    # script -- no changes needed there, the OS enforces it at the key level.
    $keyParams.UIPolicy = New-Object System.Security.Cryptography.CngUIPolicy(
        [System.Security.Cryptography.CngUIProtectionLevels]::ProtectKey,
        "Discord Sandbox",
        "Authenticate to unlock the Discord Sandbox passphrase.")
}

$cng = [System.Security.Cryptography.CngKey]::Create(
    [System.Security.Cryptography.CngAlgorithm]::Rsa,
    $KeyName,
    $keyParams)

# -AsSecureString reads keystrokes literally, so a '$' in the passphrase isn't
# interpolated the way it would be in a quoted string.
$passphrase = Read-Host "Box passphrase" -AsSecureString

# Marshal the SecureString to plaintext just long enough to encrypt it, then
# free the unmanaged buffer in the finally block.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passphrase)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $rsa   = [System.Security.Cryptography.RSACng]::new($cng)

    # Padding here must match what the unlock script uses to decrypt.
    $cipher = $rsa.Encrypt(
        [Text.Encoding]::UTF8.GetBytes($plain),
        [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)

    # The blob is useless without the TPM key, so plaintext-on-disk isn't a concern.
    [IO.File]::WriteAllBytes($CipherFile, $cipher)

    Write-Host "Setup complete. Sealed passphrase written to $CipherFile" -ForegroundColor Green
}
finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $plain = $null
}

<#
.RESETTING
    To redo setup (e.g. the passphrase changed, or you want a PIN), delete the
    existing key and the blob, then run this script again:

        $p = [System.Security.Cryptography.CngProvider]::new("Microsoft Platform Crypto Provider")
        [System.Security.Cryptography.CngKey]::Open("SbieBoxKey", $p).Delete()
        Remove-Item "$env:LOCALAPPDATA\sbiebox.bin" -ErrorAction SilentlyContinue
#>