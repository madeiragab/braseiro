@echo off
chcp 65001 >nul
title Baixar modelo
cd /d "%~dp0"

set "OLLAMA_MODELS=%~dp0models"
set "OLLAMA_HOST=127.0.0.1:11434"

set "OLLAMA_EXE="
if exist "%~dp0bin\ollama.exe" set "OLLAMA_EXE=%~dp0bin\ollama.exe"
if not defined OLLAMA_EXE for %%I in (ollama.exe) do if not "%%~$PATH:I"=="" set "OLLAMA_EXE=%%~$PATH:I"
if not defined OLLAMA_EXE (
  echo   [!] Coloque o ollama.exe em %~dp0bin primeiro. Veja o LEIA-ME.
  pause & exit /b 1
)

for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"modelo=" config.txt') do set "MODELO=%%B"

echo.
echo   Vou baixar:  %MODELO%
echo   Destino:     %~dp0models
echo.
echo   Sao uns 7 GB. Em pendrive USB 3 leva um tempo. Deixe rodando.
echo   Pra trocar de modelo, edite o config.txt antes e rode isto de novo.
echo.
pause

powershell -NoProfile -Command "try{(New-Object Net.Sockets.TcpClient).Connect('127.0.0.1',11434);exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 (
  start "Ollama" /min "%OLLAMA_EXE%" serve
  powershell -NoProfile -Command "$fim=(Get-Date).AddSeconds(45); while((Get-Date) -lt $fim){ try{ (New-Object Net.Sockets.TcpClient).Connect('127.0.0.1',11434); exit 0 }catch{ Start-Sleep -Milliseconds 400 } }; exit 1"
)

"%OLLAMA_EXE%" pull %MODELO%

echo.
echo   Feito. Agora e so o INICIAR.bat.
pause
