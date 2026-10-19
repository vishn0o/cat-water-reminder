' Cat Reminders - auto-start at boot, but only AFTER the logon crunch
' (Start Menu launches use launch-cat.vbs which starts instantly instead)
WScript.Sleep 45000
CreateObject("WScript.Shell").Run """C:\Users\sures\Documents\Default Project\cat-water-reminder\launch-cat.vbs""", 0, False
