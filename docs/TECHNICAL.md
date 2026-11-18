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
| Encrypted image, protected root | [`UseFileImage`](https://sandboxie-plus.com/sandboxie/usefileimage/), mounted with root protection | Host programs reading the box's files, at rest or while mounted |
| Confidential box | [`ConfidentialBox=y`](https://sandboxie-plus.com/sandboxie/confidentialbox/) | Host programs reading Discord's memory |
| Box-private install dir | Privacy mode, plus `WriteFilePath=%USERPROFILE%\AppData\*` in the paste template | Host programs planting code into Discord (see below) |
| Hardened token | [`SysCallLockDown`](https://sandboxie-plus.com/sandboxie/syscalllockdown/), [`DropAdminRights`](https://sandboxie-plus.com/sandboxie/dropadminrights/), Untrusted integrity | A compromised Discord reaching out of the box |
| Data Protection | [`UsePrivacyMode=y`](https://sandboxie-plus.com/privacy-mode/) | The box seeing your personal files |
| Read-only launcher and Sandboxie files | `scripts\protect-folders.ps1`, run once as administrator | Host programs editing the scripts that handle the passphrase or run inside the box, or replacing Sandboxie's `Start.exe`/`SbieDll.dll` |

What's left:

- Code that runs **inside** the box (an untrusted Discord mod or plugin). Run
  vanilla Discord and nothing else in the box.
- Malware already running as you at the moment you approve Windows Hello (see
  [TPM-sealed passphrase](#tpm-sealed-passphrase)).
- Your desktop and taskbar shortcuts live in your profile, so a host program can
  point them somewhere else. The Windows Hello prompt is then the only check:
  approve it only straight after clicking the shortcut.
- Unlocking the box from Sandboxie-Plus's own menu mounts it **without** root
  protection, so host programs can read the token while it's open. Use the
  shortcut.

### Why the scripts must be read-only

`unlock-sbiebox.ps1` handles the decrypted passphrase, and `clean-discord.vbs`
runs inside the box, where it can read the token and write to `scripts\shared`
on the host. By default every signed-in account can modify folders created on a
second drive. So any program running as you could edit either script, or swap
in its own `Start.exe` or `SbieDll.dll` for a portable install, and collect the
passphrase or the token on your next launch.

`protect-folders.ps1` makes the folder holding the repo admin-owned and
read-only for your account. It then re-opens the repo for git and
`scripts\shared` for transfers, leaving `scripts\` itself read-only. Changes to
`scripts\` (edits, `git pull`) then need an elevated prompt. Ownership matters
too: the owner of a folder can always rewrite its permissions, so the script
makes Administrators the owner.

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
Discord does not sign-check these files. No `Open…Path` rule covers the folder
now, so it falls under privacy mode's default and the paste template's
`WriteFilePath=%USERPROFILE%\AppData\*`. Both keep it box-private, and host-side
edits have no effect. Host programs, such as the taskbar, still see the host
copy, so the icon still resolves.

To check: with the box running, create `HOSTONLY.txt` in the host's
`%LocalAppData%\Discord\`, list that folder from inside the box, and confirm the
file isn't there.

#### Don't add `WriteFilePath=%LocalAppData%\Discord\`

An earlier version of this guide added that line to make the folder private
explicitly. With it, opening a file in `%LocalAppData%\Discord` by name from
inside the box reached the box's copy, but **listing** the folder returned the
host's copy. Discord's updater lists its staging folder to finish an install,
didn't find it, and failed with `The system cannot find the file specified (os
error 2)`. The splash screen then looped on "Update failed, retrying". The line
added no protection, since the `AppData` rule already covered the folder.
Removing it made in-box listings show the box's own files, and the stuck update
finished on the next start.

To check: list `%LocalAppData%\Discord` from inside the box. You should see the
box's `app-<version>` folders, not the host's.

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

The launcher used to mount with `Start.exe /key:… /mount_protected`.
[`Start.exe`](https://sandboxie-plus.com/sandboxie/startcommandline/) is a
GUI-subsystem program, so PowerShell's `&` doesn't wait for it unless its output
is piped. Without the pipe, `Update.exe` started before the box was mounted, the
launch failed silently, and the second click prompted again. The launcher now
calls `SbieDll_Mount` in-process (see
[TPM-sealed passphrase](#tpm-sealed-passphrase)), which returns only once the
service has mounted the image.

The launcher decides whether to unlock by counting the programs running in the
box, not by checking whether it's mounted. A click while the box is mounted but
empty (for example while Discord is still starting) therefore asks for Windows
Hello again.

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

### Starting Discord

The launcher starts one `wscript.exe` in the box running `start-in-box.vbs`.
That script runs the cleanup as a child, waits for it, then starts
`Update.exe --processStart Discord.exe`.

The cleanup and the start have to share one process because of how Sandboxie
handles boxes with nothing left to do. Every time a program in the box exits,
`SandboxieRpcSs` checks what's still running. If only its helpers remain
(`SandboxieRpcSs`, `SandboxieDcomLaunch`, `SandboxieCrypto`, …), it calls
`SbieDll_KillAll` and ends **every** program in the box
([`apps/com/RpcSs/linger.c`](https://github.com/sandboxie-plus/Sandboxie/blob/master/Sandboxie/apps/com/RpcSs/linger.c)).
When the cleanup ran as its own boxed process, its exit left only those helpers,
and the kill-all ended Discord's launch about a second after it began. No `SBIE`
message is logged for this, so it looked as if Discord simply never started.
Starting Discord in a box where nothing had just exited always worked.

`start-in-box.vbs` also checks that the program exists inside the box (a
host-side check would only see the host's copy), waits for `Update.exe` to hand
over to Discord, and logs its exit code. Everything goes to `launch.log`: the
unlock, the cleanup and its duration, the start, and how long the first program
took to appear. If nothing appears within `$LaunchGraceSeconds` (180 s), the
launcher logs a warning and locks the box.

While the box is mounted with root protection, Defender can't scan the box's
files. `NotifyRootProtected=y` shows this as `SBIE1317 Blocked 'MsMpEng.exe' …`.
That is root protection working as intended, and it doesn't stop Discord.

### Freeing space before each launch

The box image has a fixed size. Discord's updater unpacks each version into a
new `app-<version>` folder, stages it in `download\` and
`.app-<version>.installing`, and doesn't always remove the old ones. Once the
image is full the next version can't unpack, and the updater loops on "Update
failed, retrying".

After mounting, and only if no program runs in the box, `start-in-box.vbs` runs
`clean-discord.vbs` inside the box and waits for it (up to 120 s) before
starting `Update.exe` (see [Starting Discord](#starting-discord)). It removes:

- every `app-<version>` folder except the highest version, compared
  numerically. That's the one `Update.exe --processStart` would run anyway.
- `.app-*` folders (installs that never finished), the contents of `download\`,
  `*.old` files, and `packages\*.nupkg` for versions no longer installed;
- `%LocalAppData%\SquirrelTemp` and `%TEMP%` contents;
- Chromium caches under `%AppData%\discord` (`Cache`, `Code Cache`, `GPUCache`,
  the shader caches, service-worker caches, crash reports). It never touches
  `Local Storage`, `IndexedDB` or `settings.json`, which hold the login and
  settings. Set `CLEAR_CACHES = False` in the script to keep caches. Clearing
  them makes the first load after each launch a little slower.

It runs under `wscript.exe` because console programs can't start in the box
(see [Known issues](#known-issues)). Every path resolves to the box's own copy.
The log goes to `scripts\shared\launch.log` through the box's `OpenPipePath`,
so it can be read after the box locks. Each launch starts a fresh log; the
launcher and `start-in-box.vbs` then add their own timed lines to it. Without its log
argument the script exits at once, so double-clicking it on the host does
nothing. Set `$CleanBeforeLaunch = $false` in `unlock-sbiebox.ps1` to disable
the step.

### TPM-sealed passphrase

`setup-sbiebox.ps1` creates a non-exportable RSA key in the TPM (Microsoft
Platform Crypto Provider) with a `ProtectKey` UI policy, so every decrypt needs
Windows Hello. It then encrypts the passphrase with OAEP-SHA256 and writes only
the ciphertext to `%LOCALAPPDATA%\sbiebox.bin`. The plaintext is never stored.
To reset, see the script header.

On each launch, after you approve Windows Hello, the TPM decrypts the
passphrase into the launcher's memory as bytes. The launcher passes them to
`SbieDll_Mount` (`scripts\SbieMount.cs`) and zeroes them right after the
mount. It never puts them on a command line. `Start.exe` only accepts a password
as `/key:<password>`, and any program running as you can read other programs'
command lines without admin rights. Command-line auditing or Sysmon would also
write them to a log on disk. `Start.exe` itself does nothing more than call the
same export (`apps/start/start.cpp`).

What this can't stop: malware **already running as you** can read or inject
into the launcher's memory during the second or so the passphrase is there. It
can also ask the TPM for a decrypt itself, which raises the same Windows Hello
prompt. Approve Windows Hello only straight after clicking the shortcut. The
same limits apply to typing the password into Sandboxie-Plus.

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
