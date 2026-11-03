@echo off
cd /d "%~dp0"
if exist "%~dp0FPGA_Ethernet_Host.exe" (
  start "" "%~dp0FPGA_Ethernet_Host.exe"
  exit /b
)
if exist "%USERPROFILE%\.conda\envs\yolo\pythonw.exe" (
  start "" "%USERPROFILE%\.conda\envs\yolo\pythonw.exe" "%~dp0main.py"
  exit /b
)
python main.py
if errorlevel 1 pause
