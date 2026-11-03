@echo off
setlocal
echo ESP32-C3 PEER_ONLY_V7_WIRE_PREFIX diagnostic ONLY. B-board U33 stays unchanged.
echo Keeps the Linux PPP peer route; excludes unrelated Internet destinations from PPP.
echo Close the ESP serial monitor first; B-board COM15 may stay open.
set "ESP_PORT=COM19"
set /p "ESP_PORT=ESP32-C3 USB port [COM19]: "
if /i "%ESP_PORT%"=="COM15" (
    echo COM15 is the B-board console. Select the ESP USB port.
    pause
    exit /b 1
)
pushd "%~dp0esp32\build"
"D:\Espress\.espressif\v5.5.6\python_env\idf5.5_py3.12_env\Scripts\python.exe" -m esptool --chip esp32c3 --port "%ESP_PORT%" --baud 115200 --before default_reset --after hard_reset write_flash "@flash_args"
set "FLASH_RC=%ERRORLEVEL%"
popd
echo ESP_DIRECT_FLASH_RC=%FLASH_RC%
pause
exit /b %FLASH_RC%
