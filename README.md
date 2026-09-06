# Encrypted Sandboxie-Plus Discord Setup

> **Prerequisite:** This guide assumes a one-year Sandboxie-Plus Personal-Advanced
> subscription. The license can be reused on unlimited devices and continues to
> work after expiry — only *updates* require renewal.

---

## 1. Create the encrypted box

Create a new **secure, encrypted** box. During creation:

- Enable **"Mount Box Image"** with **"Protect Box Root From Access By Unsandboxed Processes"**.
  This protects the sandboxed filesystem from any process outside the box.
- Enable **"Lock the box when all processes stop"** so the encrypted image
  auto-unmounts once the last sandboxed program exits.

You can verify root protection is active at `C:\Sandbox\YOUR_USER` while the
sandbox is running (see [Verifying isolation](#5-verifying-isolation) below).

![alt text](image.png)

![alt text](images/image-1.png)

![alt text](images/image-2.png)

![alt text](images/image-3.png)

![alt text](images/image-4.png)

![alt text](images/image-5.png)

![alt text](images/image-6.png)

![alt text](images/image-7.png)

![alt text](images/image-8.png)

![alt text](images/image-10.png)

---

## 2. Compatibility settings (required on Windows 11)

In Sandboxie-Plus compatibility settings (**App Templates**), enable:

- **"Chromium Fix for Windows 11"**

Without this, Discord (and other Chromium-based apps) will fail to start on
Windows 11.

You should also disable "Make applications thing they are running elevated" because this interferes with Dorion's startup process.

---

## 3. Install Discord inside the box

Make sure the box is mounted WITHOUT root protection for the installation. If root protection is on, the box's file system cannot be viewed in Windows Explorer.

Open a console **inside the encrypted sandbox**:
right-click the box → **Run → Standard Applications → Command Console (Admin)**.

Then run one of the following.

**Discord (portable build):**

```cmd
curl -L -o "%USERPROFILE%\Downloads\discord-portable-setup.exe" "https://github.com/portapps/discord-portable/releases/download/1.0.9232-25/discord-portable-win64-1.0.9232-25-setup.exe"
"%USERPROFILE%\Downloads\discord-portable-setup.exe" /S
```

**Dorion (lightweight Discord client):**

```cmd
curl -L -o "%USERPROFILE%\Downloads\Dorion-setup.exe" "https://github.com/SpikeHD/Dorion/releases/download/v6.13.0/Dorion_6.13.0_x64-setup.exe"
"%USERPROFILE%\Downloads\Dorion-setup.exe"
```

Then right click the box and create a shortcut for the installed Dorion on your desktop:

![alt text](images/image-9.png)

Create a shared icons folder for programs inside and outside the sandbox to use, and use this icon for both of them.

---

## 4. Resource access

> **This is how you get files in and out of the encrypted box.**

The box's file system is sealed: with root protection on, the sandboxed
**Explorer closes immediately** and there is no in-box file browser by default,
so you cannot drag files in through a sandboxed window. To move files between
the host and the box, **one host folder is deliberately mapped through** — your
**Downloads** folder:

```
C:\Users\megatron\Downloads
```

Add this path under **Resource Access → File Access → Direct Access**
(the "Open for All Programs" option). Once set:

- Files you drop into `Downloads` from the **normal, unsandboxed Windows File
  Explorer** are visible to programs **inside** the box.
- Files saved to `Downloads` from **inside** the box are visible to the host.

`Downloads` is the single, intentional opening in an otherwise sealed box — treat
it as the airlock. Anything outside it stays isolated. Keep this path as narrow
as you're comfortable with; widening it widens the host↔box surface.

*(Optional, browse inside the box at runtime instead of relying on Downloads):*
Explorer++ is a portable file manager that runs **inside** the sandbox, giving
you an in-box browser without punching more holes through root protection:

```cmd
curl -L -o "%USERPROFILE%\Downloads\explorerpp.zip" "https://github.com/derceg/explorerplusplus/releases/download/version-1.4.0/explorerpp_x64.zip"
mkdir "%USERPROFILE%\Downloads\Explorer++"
tar -xf "%USERPROFILE%\Downloads\explorerpp.zip" -C "%USERPROFILE%\Downloads\Explorer++"
"%USERPROFILE%\Downloads\Explorer++\Explorer++.exe"
```

---

## 5. Launching Discord

Sandboxie-Plus can create shortcuts directly from its embedded viewer, or you
can launch the installed executable from a command line:

```cmd
"D:\Sandboxie\Installer\SbiePlus_x64\Start.exe" /box:YOUR_BOX_NAME cmd.exe /c start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe
```

Replace `YOUR_BOX_NAME` with your box's name. If you installed Dorion instead,
point the launch at Dorion's executable inside the box.

---

## 6. Links open outside the sandbox — msedge.exe is a breakout process

> **`msedge.exe` is configured as a breakout process, so every link you click in
> Discord opens in your normal browser *outside* the sandbox.**

This is set under **Program Control → Breakout Programs** (INI:
`BreakoutProcess=msedge.exe`). When Discord hands a URL to the browser, Sandboxie
lets that browser process "break out" and run **unsandboxed on the host**, rather
than launching a browser trapped inside the box. Practically, that means:

- Clicking a link in Discord → opens in your host browser, normal session,
  normal profile.
- The sandbox stays dedicated to Discord itself; general web browsing happens on
  the host as usual.

Substitute your actual browser's process name if you don't use Edge (e.g.
`chrome.exe`, `firefox.exe`).

**Advanced variant:** if you'd rather the broken-out browser land in a *dedicated*
web-browsing box instead of the host, pair the breakout with a
BreakoutDocument / target-box directive so the broken-out program is captured
into that other box rather than escaping to the host.

---

## 7. Verifying isolation

With the box running, confirm the sandboxed filesystem is sealed from the host.
In normal Windows File Explorer, try to open:

```
C:\Sandbox\YOUR_USER\YOUR_SANDBOX\user\current\AppData\Roaming\discord
```

Opening `C:\Sandbox\YOUR_USER` — or any path beneath it — should produce an
**Access Denied** error from Windows. If you can browse in, root protection is
not active; revisit step 1.

---

*Confirmed working on Windows 11 Pro as of 2026-02-09 with enhanced security
features enabled.*
