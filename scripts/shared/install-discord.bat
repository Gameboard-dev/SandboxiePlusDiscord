
curl -L -o "%USERPROFILE%\Downloads\DiscordSetup.exe" "https://stable.dl2.discordapp.net/distro/app/stable/win/x64/1.0.9255/DiscordSetup.exe"

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

rmdir /s /q C:\DiscordExtract

rmdir /s /q C:\DiscordApp

del /q "%USERPROFILE%\Downloads\DiscordSetup.exe"

del /q "%TEMP%\7z-installer.exe"

"%LocalAppData%\Discord\app-1.0.9255\Discord.exe"