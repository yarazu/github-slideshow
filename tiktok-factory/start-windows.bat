@echo off
rem Doppelklick startet TikTok Factory (Windows).
cd /d "%~dp0"
if exist ".venv\Scripts\pythonw.exe" (
  start "" ".venv\Scripts\pythonw.exe" app.py %*
) else (
  python app.py %*
)
