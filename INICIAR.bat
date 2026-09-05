@echo off
chcp 65001 >nul
title Braseiro
cd /d "%~dp0"

echo.
echo    ==============================
echo         B R A S E I R O
echo      mesa de RPG, so sua, local
echo    ==============================
echo.

rem ---- todos os modelos moram no pendrive, nao no C: ----
set "OLLAMA_MODELS=%~dp0models"
set "OLLAMA_HOST=127.0.0.1:11434"
set "OLLAMA_KEEP_ALIVE=30m"
set "OLLAMA_MAX_LOADED_MODELS=1"

rem ---- acha o ollama: primeiro o portatil daqui, depois o do sistema ----
set "OLLAMA_EXE="
if exist "%~dp0bin\ollama.exe" set "OLLAMA_EXE=%~dp0bin\ollama.exe"
if not defined OLLAMA_EXE for %%I in (ollama.exe) do if not "%%~$PATH:I"=="" set "OLLAMA_EXE=%%~$PATH:I"

if not defined OLLAMA_EXE (
  echo   [!] Nao achei o ollama.exe.
  echo.
  echo   Baixe o zip portatil em:
  echo     https://github.com/ollama/ollama/releases/latest
  echo     - ollama-windows-amd64.zip    ^(1.4 GB - o CUDA ja vem dentro dele^)
  echo.
  echo   Extraia ele por cima da pasta:  %~dp0bin
  echo   Tem que ficar:  %~dp0bin\ollama.exe
  echo   ^(se ficou bin\ollama-windows-amd64\ollama.exe, suba os arquivos um nivel^)
  echo.
  pause
  exit /b 1
)

rem ---- sobe o motor se ainda nao estiver de pe ----
powershell -NoProfile -Command "try{(New-Object Net.Sockets.TcpClient).Connect('127.0.0.1',11434);exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 (
  echo   Ligando o motor...
  start "Ollama" /min "%OLLAMA_EXE%" serve
  powershell -NoProfile -Command "$fim=(Get-Date).AddSeconds(45); while((Get-Date) -lt $fim){ try{ (New-Object Net.Sockets.TcpClient).Connect('127.0.0.1',11434); exit 0 }catch{ Start-Sleep -Milliseconds 400 } }; exit 1"
  if errorlevel 1 (
    echo   [!] O Ollama nao subiu em 45s. Abra a janela 'Ollama' e veja o erro.
    pause
    exit /b 1
  )
) else (
  echo   Motor ja estava ligado.
)

rem ---- o modelo do config.txt esta baixado? ----
for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"modelo=" config.txt') do set "MODELO=%%B"
"%OLLAMA_EXE%" list 2>nul | findstr /i /c:"%MODELO%" >nul
if errorlevel 1 (
  echo.
  echo   [!] O modelo "%MODELO%" ainda nao esta neste pendrive.
  echo       Rode o BAIXAR-MODELO.bat uma vez ^(precisa de internet^).
  echo.
  pause
  exit /b 1
)

rem ---- abre a mesa ----
for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"porta=" config.txt') do set "PORTA=%%B"
if not defined PORTA set "PORTA=11500"

echo   Abrindo a mesa...
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mestre\servidor.ps1"
powershell -NoProfile -Command "Start-Sleep -Milliseconds 1200"
start "" "http://localhost:%PORTA%"

echo.
echo   Pronto. Bom jogo.
echo   ^(a primeira resposta demora mais: o modelo esta subindo do pendrive^)
echo.
timeout /t 6 >nul
