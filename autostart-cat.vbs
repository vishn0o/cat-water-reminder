' Cat Reminders - auto-start at boot, but only AFTER the logon crunch
' (Start Menu launches use launch-cat.vbs which starts instantly instead)
WScript.Sleep 45000
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
shell.Run """" & here & "\launch-cat.vbs""", 0, False
