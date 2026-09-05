@echo off
chcp 65001 >nul
title Braseiro - importar modelo baixado
cd /d "%~dp0"
echo.
echo    ==============================================
echo      Importar um .gguf baixado pelo navegador
echo    ==============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mestre\importar.ps1"
