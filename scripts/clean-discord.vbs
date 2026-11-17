' Frees space inside the Discord box image before Discord starts.
'
' Why: the box image has a fixed size. Discord's updater installs each new
' version beside the old ones, and failed attempts leave half-unpacked
' ".app-<version>.installing" folders and downloads behind. Once the image is
' full the updater can't unpack the next version and loops on "Update failed,
' retrying in N seconds".
'
' Runs INSIDE the box, started by unlock-sbiebox.ps1 after the mount and before
' Update.exe, and only while nothing else runs in the box. Every path below
' resolves to the box's own copy, so nothing on the host is touched.
'
' Why VBScript under wscript.exe: console programs (cmd.exe, powershell.exe)
' can't start in a box on this Windows build (SBIE1231, docs/TECHNICAL.md,
' "Known issues"). wscript.exe is a GUI-subsystem program, and the launcher is
' already VBScript, so this adds no dependency.
'
' Usage: wscript.exe //B //NoLogo clean-discord.vbs <log file>
' The log must sit in a folder the box writes straight to the host
' (OpenPipePath), so it can be read after the box locks. Each run overwrites it.

Option Explicit

' Chromium caches are rebuilt on demand. Clearing them on every launch costs a
' slower first load (images re-downloaded, scripts recompiled) and keeps a few
' hundred MB free in the image. Set False to keep them.
Const CLEAR_CACHES = True

' Rebuilt by Discord/Chromium; never Local Storage, IndexedDB or settings,
' which hold the login and preferences.
Dim CACHE_DIRS : CACHE_DIRS = Array( _
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", _
    "DawnWebGPUCache", "GrShaderCache", "ShaderCache", _
    "Service Worker\CacheStorage", "Service Worker\ScriptCache", _
    "Crashpad\reports")

Dim fso, sh, logFile, freedTotal, failures
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set logFile = Nothing
freedTotal = 0
failures = 0

' The log argument doubles as a guard: double-clicking this file on the host
' passes none, and would otherwise clear the host's own %TEMP% and caches.
If WScript.Arguments.Count <> 1 Then WScript.Quit 2
OpenLog WScript.Arguments(0)
LogLine "INFO", "cleanup started"

Dim localApp, roamingApp, tempDir
localApp = EnvPath("%LOCALAPPDATA%")
roamingApp = EnvPath("%APPDATA%")
tempDir = EnvPath("%TEMP%")

If localApp <> "" Then CleanInstall localApp & "\Discord"
If localApp <> "" Then EmptyFolder localApp & "\SquirrelTemp", "Squirrel temp files"

If CLEAR_CACHES And roamingApp <> "" Then
    Dim c
    For Each c In CACHE_DIRS
        RemoveFolder roamingApp & "\discord\" & c, "cache"
    Next
End If

' Sanity check before emptying: a TEMP that doesn't point at a Temp folder
' (misconfigured environment) is left alone rather than wiped.
If tempDir <> "" And InStr(1, tempDir, "\Temp", vbTextCompare) > 0 Then
    EmptyFolder tempDir, "temp files"
ElseIf tempDir <> "" Then
    LogLine "WARN", "skipped %TEMP% = " & tempDir & ": not a Temp folder"
End If

LogLine "INFO", "cleanup done: freed " & Mb(freedTotal) & ", " & failures & " item(s) could not be removed"
If Not logFile Is Nothing Then logFile.Close
If failures > 0 Then WScript.Quit 1
WScript.Quit 0


' Removes every installed version except the newest, failed installs, staged
' downloads, *.old leftovers and package files for removed versions.
Sub CleanInstall(root)
    If Not fso.FolderExists(root) Then
        LogLine "WARN", "no Discord install at " & root & "; nothing to clean there"
        Exit Sub
    End If

    ' Squirrel folders are "app-1.0.9255". Update.exe --processStart runs the
    ' highest version present, so keeping the highest keeps what would run.
    ' Compared numerically: by name, app-1.0.10000 would sort below app-1.0.9999.
    Dim re : Set re = New RegExp
    re.Pattern = "^app-(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$"

    Dim names : names = SubfolderNames(root)
    Dim keepName, keepVer, n, ver
    keepName = ""
    For Each n In names
        If re.Test(n) Then
            ver = VersionOf(re, n)
            If keepName = "" Then
                keepName = n : keepVer = ver
            ElseIf CompareVersions(ver, keepVer) > 0 Then
                keepName = n : keepVer = ver
            End If
        End If
    Next

    If keepName = "" Then
        LogLine "WARN", "no app-<version> folder in " & root & "; kept all versions and packages"
    Else
        LogLine "INFO", "keeping " & keepName
        For Each n In names
            If re.Test(n) And n <> keepName Then RemoveFolder root & "\" & n, "old version"
        Next
    End If

    ' ".app-<version>.installing": an install that never finished. Never run.
    For Each n In names
        If Left(n, 5) = ".app-" Then RemoveFolder root & "\" & n, "unfinished install"
    Next

    EmptyFolder root & "\download", "staged downloads"

    ' Discord.exe.old and similar: the previous binary, kept after a swap.
    For Each n In FileNames(root)
        If LCase(Right(n, 4)) = ".old" Then RemoveFile root & "\" & n, "old binary"
    Next

    ' Discord-<version>-full.nupkg / -delta.nupkg for versions no longer
    ' installed. RELEASES and the kept version's package stay.
    If keepName <> "" And fso.FolderExists(root & "\packages") Then
        Dim tag : tag = "-" & Mid(keepName, 5) & "-"
        For Each n In FileNames(root & "\packages")
            If LCase(Right(n, 6)) = ".nupkg" And InStr(1, n, tag, vbTextCompare) = 0 Then
                RemoveFile root & "\packages\" & n, "old package"
            End If
        Next
    End If
End Sub

' Deletes everything inside a folder but keeps the folder itself, since
' Discord and Windows expect it to exist.
Sub EmptyFolder(path, label)
    If Not fso.FolderExists(path) Then Exit Sub
    Dim before, freed, n
    before = freedTotal
    For Each n In SubfolderNames(path)
        DeleteQuietly path & "\" & n, True
    Next
    For Each n In FileNames(path)
        DeleteQuietly path & "\" & n, False
    Next
    freed = freedTotal - before
    If freed > 0 Then LogLine "INFO", "emptied " & label & " in " & path & " (" & Mb(freed) & ")"
End Sub

Sub RemoveFolder(path, label)
    If Not fso.FolderExists(path) Then Exit Sub
    Dim freed : freed = DeleteQuietly(path, True)
    If freed >= 0 Then LogLine "INFO", "removed " & label & " " & path & " (" & Mb(freed) & ")"
End Sub

Sub RemoveFile(path, label)
    If Not fso.FileExists(path) Then Exit Sub
    Dim freed : freed = DeleteQuietly(path, False)
    If freed >= 0 Then LogLine "INFO", "removed " & label & " " & path & " (" & Mb(freed) & ")"
End Sub

' Deletes one file or folder tree. Returns the bytes freed, or -1 after logging
' why it failed. Failures don't stop the run: the rest still frees space.
Function DeleteQuietly(path, isFolder)
    Dim size, errNum, errDesc
    On Error Resume Next
    If isFolder Then
        size = fso.GetFolder(path).Size
        If Err.Number <> 0 Then size = 0 : Err.Clear
        fso.DeleteFolder path, True     ' True: also read-only files
    Else
        size = fso.GetFile(path).Size
        If Err.Number <> 0 Then size = 0 : Err.Clear
        fso.DeleteFile path, True
    End If
    errNum = Err.Number : errDesc = Err.Description
    On Error GoTo 0

    If errNum = 0 Then
        freedTotal = freedTotal + size
        DeleteQuietly = size
    Else
        failures = failures + 1
        LogLine "WARN", "could not remove " & path & ": error " & errNum & " (" & errDesc & _
            "). If something in the box still had it open, quit Discord, then Sandboxie-Plus > right-click the box > Terminate All Programs, and click the shortcut again."
        DeleteQuietly = -1
    End If
End Function

' Names are collected before anything is deleted: deleting while enumerating an
' FSO collection can skip entries.
Function SubfolderNames(path)
    Dim list(), i, f
    Dim folders : Set folders = fso.GetFolder(path).SubFolders
    ReDim list(folders.Count - 1)
    i = 0
    For Each f In folders
        list(i) = f.Name : i = i + 1
    Next
    SubfolderNames = list
End Function

Function FileNames(path)
    Dim list(), i, f
    Dim files : Set files = fso.GetFolder(path).Files
    ReDim list(files.Count - 1)
    i = 0
    For Each f In files
        list(i) = f.Name : i = i + 1
    Next
    FileNames = list
End Function

Function VersionOf(re, name)
    Dim m : Set m = re.Execute(name)(0)
    VersionOf = Array(Num(m.SubMatches(0)), Num(m.SubMatches(1)), Num(m.SubMatches(2)), Num(m.SubMatches(3)))
End Function

Function Num(s)
    If Len(s & "") = 0 Then Num = 0 Else Num = CDbl(s)
End Function

Function CompareVersions(a, b)
    Dim i
    For i = 0 To 3
        If a(i) > b(i) Then CompareVersions = 1 : Exit Function
        If a(i) < b(i) Then CompareVersions = -1 : Exit Function
    Next
    CompareVersions = 0
End Function

' Expands one variable; "" (and a logged warning) if it isn't set, so no path
' is ever built on a literal "%TEMP%" or on the drive root.
Function EnvPath(name)
    Dim v : v = sh.ExpandEnvironmentStrings(name)
    If v = name Or Len(v) < 4 Then
        LogLine "WARN", name & " is not set; skipped everything under it"
        EnvPath = ""
    Else
        If Right(v, 1) = "\" Then v = Left(v, Len(v) - 1)
        EnvPath = v
    End If
End Function

Sub OpenLog(path)
    On Error Resume Next
    Set logFile = fso.CreateTextFile(path, True)
    If Err.Number <> 0 Then Set logFile = Nothing
    On Error GoTo 0
End Sub

Sub LogLine(level, msg)
    If logFile Is Nothing Then Exit Sub
    logFile.WriteLine Stamp() & " " & level & " " & msg
End Sub

Function Stamp()
    Dim t : t = Now
    Stamp = Year(t) & "-" & Pad(Month(t)) & "-" & Pad(Day(t)) & " " & _
        Pad(Hour(t)) & ":" & Pad(Minute(t)) & ":" & Pad(Second(t))
End Function

Function Pad(v)
    Pad = Right("0" & v, 2)
End Function

Function Mb(bytes)
    Mb = FormatNumber(bytes / 1048576, 1) & " MB"
End Function
