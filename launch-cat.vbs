' Cat Reminders - starts the cat with NO visible console window
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\sures\Documents\Default Project\cat-water-reminder\cat-reminders.ps1""", 0, False
