@echo off
chcp 65001 >nul
cd /d "%~dp0"
title mouse-ctrl-v3 - 手机控制电脑鼠标

echo.
echo ═══════════════════════════════════════
echo    🖱️  mouse-ctrl-v3 · 手机控制电脑鼠标
echo ═══════════════════════════════════════
echo.

echo [1/3] 关闭旧服务...
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8642.*LISTENING"') do (
    taskkill /PID %%a /F >nul 2>&1
)
timeout /t 1 /nobreak >nul

echo [2/3] 启动服务器...
start "" /B node server.js
timeout /t 2 /nobreak >nul

echo [3/3] 打开控制页面...
start http://localhost:8642

echo.
echo ✅ 已启动！
echo    📍 PC 页面:   http://localhost:8642
echo    📱 手机:      扫页面上的二维码（和电脑连同一个 WiFi）
echo    🎮 触摸板控制  控制鼠标移动/点击/滚轮/键盘
echo    🔼🔽 滚轮遥控  只有上下箭头，按住连续丝滑滚动
echo.
echo 提示：首次运行若弹出防火墙提示，请勾选「专用网络」并允许。
echo.
echo 按任意键退出本窗口（服务器继续在后台运行）...
pause >nul
