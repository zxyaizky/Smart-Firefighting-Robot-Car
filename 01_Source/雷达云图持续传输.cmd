@echo off
setlocal
title Lidar HDMI - Continuous Transfer
echo Connect Anlu-B-Linux; keep radar, STM32, B and ESP powered.
echo Close L150 and other readers of the lidar Bluetooth port. COM15 is not required.
echo Runs continuously. Press Ctrl+C to stop.
set "LIDAR_PORT="
set /p "LIDAR_PORT=Lidar Bluetooth port [COM22]: "
if not defined LIDAR_PORT set "LIDAR_PORT=COM22"
"D:\anaconda\python.exe" "%~dp0test\b_vexriscv_main_20261013\work_B\firmware\linux_wifi\lidar_hdmi\send_map.py" --port "%LIDAR_PORT%" --seconds 0
set "MAP_RC=%ERRORLEVEL%"
echo LIDAR_HDMI_SEND_RC=%MAP_RC%
pause
exit /b %MAP_RC%
