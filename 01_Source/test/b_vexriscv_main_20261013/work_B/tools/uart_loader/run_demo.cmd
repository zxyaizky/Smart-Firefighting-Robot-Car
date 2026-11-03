@echo off
setlocal
set "uart_port=COM15"
set /p "uart_port=Board serial port [COM15]: "
"D:\anaconda\python.exe" "%~dp0upload.py" "%~dp0examples\ddr_uart_hello.bin" --port "%uart_port%" --monitor
pause
