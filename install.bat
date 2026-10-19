@echo off
rem Cat Reminders - installs into %LOCALAPPDATA%\CatReminders and wires autostart
setlocal
set DEST=%LOCALAPPDATA%\CatReminders

echo Cat Reminders installer
echo.
echo Installing to %DEST% ...
if not exist "%DEST%" mkdir "%DEST%"
copy /y "%~dp0cat-reminders.ps1" "%DEST%" >nul
copy /y "%~dp0catproc.dll" "%DEST%" >nul
copy /y "%~dp0launch-cat.vbs" "%DEST%" >nul
copy /y "%~dp0autostart-cat.vbs" "%DEST%" >nul
copy /y "%~dp0cat.png" "%DEST%" >nul 2>nul
copy /y "%~dp0meow.wav" "%DEST%" >nul 2>nul
if exist "%~dp0meows" xcopy /e /i /y "%~dp0meows" "%DEST%\meows" >nul

echo Creating Start Menu shortcut...
powershell -NoProfile -Command ^
 "$ws = New-Object -ComObject WScript.Shell;" ^
 "$sm = [Environment]::GetFolderPath('Programs');" ^
 "$s = $ws.CreateShortcut($sm + '\Cat Reminders.lnk');" ^
 "$s.TargetPath = 'wscript.exe'; $s.Arguments = '\"%LOCALAPPDATA%\CatReminders\launch-cat.vbs\"'; $s.Save()"

echo Creating logon auto-start...
powershell -NoProfile -Command ^
 "$ws = New-Object -ComObject WScript.Shell;" ^
 "$su = [Environment]::GetFolderPath('Startup');" ^
 "$s = $ws.CreateShortcut($su + '\Cat Reminders.lnk');" ^
 "$s.TargetPath = 'wscript.exe'; $s.Arguments = '\"%LOCALAPPDATA%\CatReminders\autostart-cat.vbs\"'; $s.Save()"

echo Starting the cat ...
wscript.exe "%DEST%\launch-cat.vbs"
echo.
echo Done. The cat lives next to your clock now.
echo (reminders.json keeps your data; uninstall.bat removes everything)
pause
