The following guide assumes a Year's Sandboxie-Personal-Advanced subscription.
This can be reused on unlimited devices and can be used after the license expiry - although updates require renewal.

Create a new secure-encrypted box. Make sure to **"Mount Box Image"** with **"Protect Box Root From Access By Unsandboxed Processes"**. This protects the sandboxed filesystem from external access. You can verify this at `C:\Sandbox\YOUR_USER` when the sandbox is active. Also check **"Lock the box when all processes top"**.

The following setting should be enabled in Sandboxie-Plus's compatibility settings (**App Templates**) or Discord will fail to initiate on Windows 11: **"Chromium Fix for Windows 11"**.

Then run the following commands inside the encrypted sandbox:

```cmd

curl -L -o "%USERPROFILE%\Downloads\DiscordSetup.exe" "https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x64"

curl -L -o "%TEMP%\7z-installer.exe" "https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.exe"

"%TEMP%\7z-installer.exe" /S

"C:\Program Files\7-Zip\7z.exe" x "%USERPROFILE%\Downloads\DiscordSetup.exe" -oC:\DiscordExtract -y

"C:\Program Files\7-Zip\7z.exe" x "C:\DiscordExtract\Discord-1.0.9255-full.nupkg" -oC:\DiscordApp -y

mkdir "%LocalAppData%\Discord\app-1.0.9255"

xcopy "C:\DiscordApp\lib\net45\*" "%LocalAppData%\Discord\app-1.0.9255\" /E /I /Y

copy C:\DiscordExtract\Update.exe "%LocalAppData%\Discord\Update.exe" /Y

mkdir "%LocalAppData%\Discord\packages"

copy C:\DiscordExtract\Discord-1.0.9255-full.nupkg "%LocalAppData%\Discord\packages\" /Y

copy C:\DiscordExtract\RELEASES "%LocalAppData%\Discord\packages\" /Y

"%LocalAppData%\Discord\app-1.0.9255\Discord.exe"

```

Sandboxie-Plus provides an embedded viewer inside the app for creating shortcuts directly, or you can execute the following command to run your installed Discord executable directly:

```cmd
"D:\Sandboxie\Installer\SbiePlus_x64\Start.exe" /box:YOUR_BOX_NAME cmd.exe /c start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe
```

Verify that the Sandbox directory cannot be accessed in Windows File Explorer outside the box:
`C:\Sandbox\YOUR_USER\YOUR_SANDBOX\user\current\AppData\Roaming\discord`. Attempting to open `C:\Sandbox\YOUR_USER` or any path after it should result in an **access denied** error from Windows.

**Working on Windows 11 Pro as of 02/09/2026 with enhanced security features enabled**

