@echo off
setlocal
cd /d "%~dp0"
title WeMM 素材检索 - 一键部署
echo ============================================================
echo    WeMM 素材检索 - 一键部署
echo    双击本文件即可自动安装并配置运行环境（可重复运行）
echo ============================================================
echo.
where powershell >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 powershell，无法继续。请确认系统为 Windows 10/11。
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy_wemm.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" goto done
echo ------------------------------------------------------------
echo [提示] 部署脚本退出码为 %RC% ，上方有具体失败原因与处理建议。
echo [提示] 排除问题后，再次双击本文件即可续跑（已装好的部分会跳过）。
echo ------------------------------------------------------------
if not "%RC%"=="11" pause
:done
endlocal
