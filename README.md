The following guide assumes a Year's Sandboxie-Personal-Advanced subscription.
This can be reused on unlimited devices and can be used after the license expiry - although updates require renewal.

Run the following commands inside a Sandboxie-Plus encrypted sandbox:

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

Execute the following command to run your installed Discord executable
in a Windows Shortcut.

You could pass the unlock password to the shortcut using the following command:
```cmd
"D:\Sandboxie\Installer\SbiePlus_x64\Start.exe" /key:YOUR_PASSWORD_HERE /box:Discord /mount
"D:\Sandboxie\Installer\SbiePlus_x64\Start.exe" /box:YOUR_BOX_NAME cmd.exe /c start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe --process-start-args="--no-sandbox"
```

However, this is insecure, and in practice Sandboxie-Plus recommends unlocking the box once
with a password and then executing:
```cmd
"D:\Sandboxie\Installer\SbiePlus_x64\Start.exe" /box:YOUR_BOX_NAME cmd.exe /c start "" "%LocalAppData%\Discord\Update.exe" --processStart Discord.exe --process-start-args="--no-sandbox"
```

Working on Windows 11 Pro as of 02/09/2026 with security features enabled.

Note the following setting should be enabled in Sandboxie-Plus's compatibility settings (**App Templates**) or Discord will fail to initiate on Windows 11: **"Chromium Fix for Windows 11"**.

