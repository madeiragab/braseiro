@echo off
chcp 65001 >nul
title Braseiro - criar atalho
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mestre\atalho.ps1"
pause
