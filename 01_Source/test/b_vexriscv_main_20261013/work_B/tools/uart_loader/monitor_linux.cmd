@echo off
setlocal
set "BOARD_PORT=COM15"
set /p "BOARD_PORT=Board serial port [COM15]: "
"D:\anaconda\python.exe" "%~dp0run_linux.py" --port "%BOARD_PORT%" --monitor-only
pause
