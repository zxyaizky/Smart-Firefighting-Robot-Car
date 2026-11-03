@echo off
setlocal
set "BOARD_PORT=COM15"
set /p "BOARD_PORT=Board serial port [COM15]: "
"D:\anaconda\python.exe" "%~dp0upload.py" "%~dp0..\linux_timer_probe\linux_timer_probe.bin" --port "%BOARD_PORT%" --monitor
pause
