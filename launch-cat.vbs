' Cat Reminders - starts the cat with NO visible console window.
' Works from wherever the folder is installed (uses its own location).
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\cat-reminders.ps1""", 0, False
