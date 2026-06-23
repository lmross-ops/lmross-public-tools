@echo off
REM LMRoss-ConnectionTest.cmd - double-click to run
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/lmross/lmross-tools/main/Test-RemoteUserConnection.ps1 | iex"
pause