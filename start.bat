@echo off
chcp 65001 >nul
cd /d "%~dp0"
title mouse-ctrl-v3 - Phone Mouse Control

REM ---- make sure firewall allows phone access (first run asks for UAC once) ----
netsh advfirewall firewall show rule name="mouse-ctrl-v3" | findstr "mouse-ctrl-v3" >nul 2>&1
if errorlevel 1 (
    net session >nul 2>&1
    if errorlevel 1 (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        exit /b
    )
    netsh advfirewall firewall add rule name="mouse-ctrl-v3" dir=in action=allow protocol=TCP localport=8642 >nul
    echo Firewall rule added: allow TCP 8642 (phones can now connect)
)

echo.
echo ============================================
echo    mouse-ctrl-v3 : control PC mouse by phone
echo ============================================
echo.

echo [1/3] Stopping old service ...
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8642.*LISTENING"') do (
    taskkill /PID %%a /F >nul 2>&1
)
ping -n 2 127.0.0.1 >nul

echo [2/3] Starting server ...
start "" /B node server.js
ping -n 3 127.0.0.1 >nul

echo [3/3] Opening control page ...
start http://localhost:8642

echo.
echo DONE! Scan the QR code on the page with your phone.
echo (Phone and PC must be on the same WiFi.)
echo.
echo Press any key to close this window (server keeps running)...
pause >nul
