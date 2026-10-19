@echo off
rem Cat Reminders - clean removal: shortcuts, autostart and the program folder
echo Removing Cat Reminders...
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Cat Reminders.lnk" 2>nul
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Cat Reminders.lnk" 2>nul
taskkill /fi "windowtitle eq Cat Reminders" >nul 2>nul
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'cat-reminders' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>nul
timeout /t 2 >nul
rd /s /q "%LOCALAPPDATA%\CatReminders"
echo Done. The cat has left the house.
pause
