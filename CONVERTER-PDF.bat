@echo off
chcp 65001 >nul
title Braseiro - converter PDF dos livros
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mestre\converter.ps1"
