@echo off
title Cat Reminders
echo Starting the cat (pops up based on your reminders)...
echo Closing the panel keeps the cat running in the system tray.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cat-reminders.ps1"
