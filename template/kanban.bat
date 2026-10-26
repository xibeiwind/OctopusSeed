@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File .\tools\serve-kanban.ps1 -Port 5180
