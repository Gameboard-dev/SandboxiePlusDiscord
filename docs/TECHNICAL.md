# Technical Notes

How and why each part of this setup works. The [README](../README.md) is the
step-by-step guide; this page is for when you want the reasoning, or need to
debug or change something.

Tested on Windows 11 Pro build 26300 with Sandboxie-Plus 1.18.8. Source
references are to [sandboxie-plus/Sandboxie](https://github.com/sandboxie-plus/Sandboxie).

---

## Threat model

The goal is that **Discord's session token never exists outside the encrypted
box image**. Discord stores it in `%AppData%\discord\Local Storage\leveldb`. On a
normal install, any program running as you can copy it — that is how token
grabbers work.

| Layer | Setting | Stops |
|---|---|---|
| Encrypted image, protected root | [`UseFileImage`](https://sandboxie-plus.com/sandboxie/usefileimage/), mount with `/mount_protected` | Host programs reading the box's files, at rest or while mounted |
| Confidential box | [`ConfidentialBox=y`](https://sandboxie-plus.com/sandboxie/confidentialbox/) | Host programs reading Discord's memory |
| Box-private install dir | `WriteFilePath=%LocalAppData%\Discord\` | Host programs planting code into Discord (see below) |
| Hardened token | [`SysCallLockDown`](https://sandboxie-plus.com/sandboxie/syscalllockdown/), [`DropAdminRights`](https://sandboxie-plus.com/sandboxie/dropadminrights/), Untrusted integrity | A compromised Discord reaching out of the box |
| Data Protection | [`UsePrivacyMode=y`](https://sandboxie-plus.com/privacy-mode/) | The box seeing your personal files |

What's left: code that runs **inside** the box (an untrusted Discord mod or
plugin). Run vanilla Discord and nothing else in the box.

---

## How file rules decide where data goes

Sandboxie finds every rule matching a path and uses the **most specific** one
(the longest literal match). [Rule specificity](https://sandboxie-plus.com/sandboxie/rulespecificity/)
is always on in Data Protection mode. The winning rule's type decides:

| Rule type | Reads come from | Writes go to |
|---|---|---|
| [`WriteFilePath`](https://sandboxie-plus.com/sandboxie/writefilepath/), and privacy mode's default for drives | the box's own copy (host copy hidden) | the box's own copy, inside the encrypted image |
| [`ReadFilePath`](https://sandboxie-plus.com/sandboxie/readfilepath/) | the host | nowhere — refused |
| [`OpenFilePath`](https://sandboxie-plus.com/sandboxie/openfilepath/) / [`OpenPipePath`](https://sandboxie-plus.com/sandboxie/openpipepath/) | the host | **the host** |
| `NormalFilePath` (privacy mode: `Windows`, `Program Files`, `ProgramData\Microsoft`) | host, then box copy | the box's copy |

Consequences:

- `WriteFilePath` is misleadingly named — it means *box-private*, not *write to
  the host*.
- Only `Open…Path` rules can put data on the host. This config has three:
  `Downloads`, `Documents`, and `scripts\shared`. None covers `AppData`.
- A `ReadFilePath` can never leak data out; at worst it makes a path read-only.

### The paste template

`[Template_Local_ReadHostFiles]` pairs drive-wide `ReadFilePath=C:\*` (3
characters) with `WriteFilePath=%USERPROFILE%\AppData\*` (26 characters). The
longer rule wins under `AppData`, so it stays box-private. Keeping both lines in
one template means they can't be toggled separately.

What happens if the `AppData` rule goes missing (it was once commented out on
its own):

- the box sees the host's `AppData\Roaming` read-only — browser profiles
  included;
- Discord's in-box profile is hidden behind it, so Discord fails with
  `EPERM: operation not permitted, mkdir '…\AppData\Roaming\discord\…'`;
- nothing is written to the host — the `ReadFilePath` refuses the write.

Verified with a test program in the box (template applied): writing a marker to
`%AppData%\discord` worked and left no copy anywhere on the host; host-only
`Roaming\Mozilla` and `Local\Microsoft\Edge` were invisible; `.ssh`, `.config`
and `.claude` showed by name in the profile listing but could not be opened;
files in `Pictures` and on `D:` were readable but not writable.

### Why the install directory is box-private

With `OpenFilePath=%LocalAppData%\Discord\` (an older version of this guide),
the box read Discord's program files from the host. Any host process running as
you — no admin needed — could edit

```
%LocalAppData%\Discord\app-<version>\modules\discord_desktop_core-1\discord_desktop_core\index.js
```

and Discord would run that code inside the box, with the token in memory.
Discord does not sign-check these files. `WriteFilePath` hides the host copy
from the box, so host-side edits have no effect. Host programs, such as the
taskbar, still see the host copy, so the icon still resolves.

To check: with the box running, create `HOSTONLY.txt` in the host's
`%LocalAppData%\Discord\`, list that folder from inside the box, and confirm the
file isn't there.

---

## Why the install script uses an older Discord

Discord's native updater (`updater.node`, loaded on every launch) validates the
install against Discord's servers. On a hand-installed copy of the **current**
version it tries to finalize the running version, finds `Discord.exe` running
from the target folder, and throws
`InconsistentInstallerState: Attempt to install host that is currently running`.
The window flashes and closes.

An install that is **behind** the server (1.0.9255 in the script) takes the
normal update path instead: Discord downloads and applies the new version in the
background. The old version is only a bootstrap. The official installer can't
be used because it fails in a Data Protection box.

---

## Voice, audio, camera and screen share

### `UseSecurityMode` is split into its parts

[`UseSecurityMode=y`](https://sandboxie-plus.com/sandboxie/usesecuritymode/)
combines `SysCallLockDown`, `DropAdminRights`, and `RestrictDevices`. The driver
reads it as

```c
// core/drv/process.c
proc->restrict_devices = proc->use_security_mode || Conf_Get_Boolean(..., L"RestrictDevices", ...);
```

so `RestrictDevices=n` can't override it. The config lists the parts
separately, leaving [`RestrictDevices`](https://sandboxie-plus.com/sandboxie/restrictdevices/)
off. That setting closes `\Device\*` except a short allow-list
(`[TemplateSModPaths]` in `Templates.ini`) and blocks camera and capture devices.

`SysCallLockDown` itself doesn't block audio: its approved list already includes
`AlpcConnectPort`, `DeviceIoControlFile`, and the other calls the audio stack
uses.

### Playback: `LessConfidentialBox`

`ConfidentialBox=y` gives host processes no access at all to boxed processes
(`Thread_CheckObject_CommonEx` in `core/drv/thread.c`). The only exceptions are
SbieSvc, Start.exe, csrss, lsass, protected processes, conhost and Task Manager,
plus any `DenyHostAccess=<image>,n`. `Template=LessConfidentialBox` adds
`audiodg.exe`, the Windows audio engine. Exceptions match by **image name
only**, so any host process named `audiodg.exe` passes too.
`NotifyBoxProtected=y` logs each refusal as SBIE1318.

### Microphone: the token identity

Since a recent Windows 11 update, microphone capture fails in **every**
Sandboxie box: [#5615](https://github.com/sandboxie-plus/Sandboxie/issues/5615),
[#5672](https://github.com/sandboxie-plus/Sandboxie/issues/5672).
`IAudioClient::Initialize` returns `E_INVALIDARG` (`0x80070057`) inside a box —
including a default, unhardened one — while the same call succeeds on the host.
Playback is unaffected.

Before restricting the token, Sandboxie swaps the token's user SID for a per-box
Sandboxie account (`SandboxieLogon=y`) or Anonymous Logon (`core/drv/token.c`,
`core/svc/DriverAssistInject.cpp`). Windows now refuses capture for that
identity. Each setting was tested alone with a WASAPI capture probe started in
the box:

| Token settings | Capture |
|---|---|
| defaults | fails |
| `NoUntrustedToken=y` (Low instead of Untrusted integrity) | fails |
| `KeepLogonSession=y` | fails |
| `SandboxieLogon=n` + `AnonymousLogon=n` | **works** |
| `OriginalToken=y` | works |

`SandboxieLogon=n` + `AnonymousLogon=n` keep your real user SID as the token's
identity. It is still **deny-only**: every group is deny-only, privileges are
stripped, and integrity stays Untrusted, so the token passes no access check that
your account would. Both lines are needed: `AnonymousLogon` only matters once
`SandboxieLogon` is off. The cost is that the box loses its own synthetic
identity.

[`OriginalToken=y`](https://sandboxie-plus.com/sandboxie/originaltoken/) gives
boxed processes your full token (groups enabled, Medium integrity), and
Sandboxie flags the box as an insecure configuration. Under it, processes
inherit their parent's token, so a Discord that restarts itself keeps the old
one. Empty the box before relaunching after you toggle it.

Things tested that did **not** help capture: `DenyHostAccess=svchost.exe,n`,
`OpenDevCMApi=y`, and turning off `RestrictDevices`.

---

## The launcher

### One click, one prompt

[`Start.exe`](https://sandboxie-plus.com/sandboxie/startcommandline/) is a
GUI-subsystem program, so PowerShell's `&` doesn't wait for it — and doesn't set
`$LASTEXITCODE` — unless its output is piped. Without the pipe, the
`/mount_protected` call returned at once, the error check read a stale exit
code, and `Update.exe` started before the box was mounted. The launch failed
silently, leaving a mounted but empty box, so the second click prompted again
and worked. `unlock-sbiebox.ps1` now pipes the mount call to `Out-Null`.

### Locking again on exit

Boxes mounted through `Start.exe /mount` or `/mount_protected` never
auto-unmount: `SbieDll_Mount` (`core/dll/support.c`) hard-codes
`auto_unmount = FALSE`, and the INI lookup for it in `core/svc/MountManager.cpp`
is commented out. So the box's "lock when all processes stop" option doesn't
apply. The launcher instance that mounted the box therefore stays running
(hidden). It polls `Start.exe /box:Discord /listpids` every 5 s and runs
`/unmount` once the box has been empty for two polls in a row. The service
refuses to unmount while anything runs. Set `$UnmountWhenEmpty = $false` to
disable this.

### TPM-sealed passphrase

`setup-sbiebox.ps1` creates a non-exportable RSA key in the TPM (Microsoft
Platform Crypto Provider) with a `ProtectKey` UI policy, so every decrypt needs
Windows Hello. It then encrypts the passphrase with OAEP-SHA256 and writes only
the ciphertext to `%LOCALAPPDATA%\sbiebox.bin`. The plaintext is never stored.
To reset, see the script header.

The passphrase is briefly visible on `Start.exe`'s command line during the
mount, to anything that inspects local processes.

---

## Known issues

- **Console programs can't start in any box** on Windows build 26300 with
  Sandboxie-Plus 1.18.8. `SBIE1231 Initialization failed [C0000038 / 66]` comes
  from `Process_Low_InitConsole` (`core/drv/process_low.c`), which finds itself
  in the wrong process context (`STATUS_DEVICE_ALREADY_ATTACHED`). It's followed
  by `[C0000001 / A8]` (init step 8) and SBIE2314. GUI programs, including
  Discord, are unaffected. To run diagnostics in the box, use a
  GUI-subsystem tool (`csc /target:winexe`).
- **Programs launched into the box can't see the host `%TEMP%`** with this
  config, because it sits under `AppData`. Stage test files in `Downloads`.

---

## Diagnosing problems

- **Messages:** every `SBIExxxx` code in Sandboxie-Plus's Messages panel has a
  documentation page, for example [SBIE2314](https://sandboxie-plus.com/sandboxie/sbie2314/).
- **Tracing:** uncomment the `#…Trace=D` lines in `Sandboxie.ini`, reload,
  reproduce the problem, then read the denied entries in the Trace Log
  ([FileTrace](https://sandboxie-plus.com/sandboxie/filetrace/)).
- **Host access:** `NotifyBoxProtected=y` names each host process that
  `ConfidentialBox` refuses ([docs](https://sandboxie-plus.com/sandboxie/notifyboxprotected/)).
- **Source:** the driver code under `Sandboxie/core/drv/` answers most "why"
  questions; `gh search code <Setting> --repo sandboxie-plus/Sandboxie` finds
  where a setting is read. `SbieSettings.ini` in the install folder documents
  every setting.
