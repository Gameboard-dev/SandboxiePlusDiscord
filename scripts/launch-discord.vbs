Dim fso, here, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\unlock-sbiebox.ps1"
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False