@echo off
setlocal
set "BOARD_PORT=COM15"
set /p "BOARD_PORT=B-board USB console port [COM15]: "
"D:\anaconda\python.exe" "%~dp0upload_wifi.py" --port "%BOARD_PORT%"
pause
