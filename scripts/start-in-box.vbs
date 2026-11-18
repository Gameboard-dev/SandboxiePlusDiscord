' Runs INSIDE the box: optionally runs the cleanup, then starts a program, and
' logs each step.
'
' Why one script for both: SandboxieRpcSs kills every program in the box as
' soon as only its own helpers (SandboxieRpcSs, SandboxieDcomLaunch,
' SandboxieCrypto, ...) are left running (apps/com/RpcSs/linger.c, which ends in
' SbieDll_KillAll). When the cleanup ran as its own boxed process, its exit left
' only those helpers, and the kill-all took out Discord's launch a second later.
' Here this script stays alive from the cleanup until the program has started,
' so the box is never down to helpers in between.
'
' Started by unlock-sbiebox.ps1 through `Start.exe /box:<box> wscript.exe ...`.
' wscript.exe rather than PowerShell: console programs can't start in the box
' on this Windows build (docs/TECHNICAL.md, "Known issues").
'
' Usage: wscript.exe //B //NoLogo start-in-box.vbs <log file> <cleanup script | -> <program> [args...]

Option Explicit

' Longest the cleanup may run before Discord is started anyway.
Const CLEAN_TIMEOUT_S = 120

Dim fso, sh, args, logPath, cleanScript, program, cmd, i, rc, t0, errNum, errDesc
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set args = WScript.Arguments
If args.Count < 3 Then WScript.Quit 2
logPath = args(0)
cleanScript = args(1)
program = args(2)

If cleanScript <> "-" Then RunCleanup cleanScript

' Checked here, inside the box: the launcher on the host would only see the
' host's copy of the path.
If Not fso.FileExists(program) Then
    LogLine "WARN", program & " not found inside the box; nothing started. Reinstall Discord in the box (README, Step 3)."
    WScript.Quit 1
End If

cmd = Quote(program)
For i = 3 To args.Count - 1
    cmd = cmd & " " & Quote(args(i))
Next

' Wait for the program: Update.exe --processStart exits once Discord is up,
' so its exit code says whether the hand-over worked.
t0 = Timer
On Error Resume Next
rc = sh.Run(cmd, 1, True)
errNum = Err.Number : errDesc = Err.Description
On Error GoTo 0

If errNum <> 0 Then
    LogLine "WARN", "could not start " & program & ": error " & errNum & " (" & errDesc & ")"
    WScript.Quit 1
End If
LogLine "INFO", "started " & program & "; it exited with " & rc & " after " & FormatNumber(Timer - t0, 1) & " s"
WScript.Quit 0


' Runs the cleanup as a child process and waits for it, so this script, and
' with it the box, stays busy until the cleanup is done.
Sub RunCleanup(script)
    If Not fso.FileExists(script) Then
        LogLine "WARN", script & " not found; skipped cleanup. Restore it from the repo."
        Exit Sub
    End If
    ' Not named "wscript": VBScript names ignore case, so that would hide the
    ' built-in WScript object.
    Dim hostExe, job, start
    hostExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\wscript.exe"
    start = Timer
    On Error Resume Next
    Set job = sh.Exec(Quote(hostExe) & " //B //NoLogo " & Quote(script) & " " & Quote(logPath))
    If Err.Number <> 0 Then
        LogLine "WARN", "could not run the cleanup: error " & Err.Number & " (" & Err.Description & ")"
        Exit Sub
    End If
    On Error GoTo 0
    Do While job.Status = 0 And Timer - start < CLEAN_TIMEOUT_S
        WScript.Sleep 200
    Loop
    If job.Status = 0 Then
        job.Terminate
        LogLine "WARN", "cleanup still running after " & CLEAN_TIMEOUT_S & " s; stopped it and started Discord anyway"
    Else
        LogLine "INFO", "cleanup step took " & FormatNumber(Timer - start, 1) & " s"
    End If
End Sub

Function Quote(s)
    If s = "" Or InStr(s, " ") > 0 Then Quote = """" & s & """" Else Quote = s
End Function

' Appends: the launcher, the cleanup and this script share one log per launch.
' A failed write is ignored rather than stopping the launch.
Sub LogLine(level, msg)
    On Error Resume Next
    Dim f, t
    t = Now
    Set f = fso.OpenTextFile(logPath, 8, True)
    f.WriteLine Year(t) & "-" & Pad(Month(t)) & "-" & Pad(Day(t)) & " " & Pad(Hour(t)) & ":" & _
        Pad(Minute(t)) & ":" & Pad(Second(t)) & " " & level & " box: " & msg
    f.Close
End Sub

Function Pad(v)
    Pad = Right("0" & v, 2)
End Function
