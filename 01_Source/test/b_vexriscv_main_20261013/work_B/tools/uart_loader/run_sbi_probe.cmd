@echo off
setlocal
set "BOARD_PORT=COM15"
set /p "BOARD_PORT=Board serial port [COM15]: "
"D:\anaconda\python.exe" "%~dp0run_sbi_probe.py" --port "%BOARD_PORT%"
pause
