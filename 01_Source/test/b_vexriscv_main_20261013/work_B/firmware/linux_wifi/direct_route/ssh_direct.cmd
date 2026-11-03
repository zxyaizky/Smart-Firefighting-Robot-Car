@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\ssh_windows.ps1" -Direct
pause
