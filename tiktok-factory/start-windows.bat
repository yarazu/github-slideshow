@echo off
rem TikTok Factory - Start per Doppelklick (Windows).
rem Beim ersten Mal richtet diese Datei alles ein: Python-Umgebung, Pakete, ffmpeg.
setlocal
title TikTok Factory
cd /d "%~dp0"

rem --- Python 3.11+ suchen -------------------------------------------------
set "PY="
py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" >nul 2>&1
if not errorlevel 1 set "PY=py -3"
if defined PY goto have_python
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" >nul 2>&1
if not errorlevel 1 set "PY=python"
if defined PY goto have_python

echo.
echo  Python 3.11 oder neuer wurde nicht gefunden.
echo  TikTok Factory braucht Python. Es wird einmalig installiert.
echo.
choice /C JN /M "  Python jetzt automatisch installieren"
if errorlevel 2 goto no_python
winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
echo.
echo  Fertig. Bitte dieses Fenster schliessen und die Datei erneut doppelklicken.
pause
exit /b 1

:no_python
echo.
echo  Bitte Python von https://www.python.org/downloads/ installieren
echo  (im Installer den Haken bei "Add python.exe to PATH" setzen)
echo  und diese Datei danach erneut doppelklicken.
pause
exit /b 1

:have_python
rem --- Einmalige Einrichtung -----------------------------------------------
if exist ".venv\Scripts\python.exe" goto have_venv
echo  Erste Einrichtung: Python-Umgebung wird angelegt ...
%PY% -m venv .venv
if errorlevel 1 goto setup_failed

:have_venv
fc /b requirements.txt ".venv\requirements.installiert" >nul 2>&1
if not errorlevel 1 goto have_packages
echo  Pakete werden installiert. Das dauert beim ersten Mal einige Minuten ...
".venv\Scripts\python.exe" -m pip install --upgrade pip >nul 2>&1
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto setup_failed
copy /y requirements.txt ".venv\requirements.installiert" >nul

:have_packages
rem --- ffmpeg ---------------------------------------------------------------
where ffmpeg >nul 2>&1
if not errorlevel 1 goto have_ffmpeg
echo.
echo  ffmpeg fehlt. Es wird zum Rendern der Videos gebraucht.
choice /C JN /M "  ffmpeg jetzt automatisch installieren"
if errorlevel 2 goto have_ffmpeg
winget install -e --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements
echo.
echo  Fertig. Bitte dieses Fenster schliessen und die Datei erneut doppelklicken.
pause
exit /b 1

:have_ffmpeg
rem --- Start (mit Rueckfall, falls das durchsichtige Fenster nicht geht) ---
echo.
echo  TikTok Factory startet. Dieses Fenster offen lassen: Beim Schliessen endet die App.
".venv\Scripts\python.exe" app.py %*
if exist "logs\start.ok" goto end
echo.
echo  Das Fenster ist nicht richtig gestartet. Zweiter Versuch ohne Transparenz ...
".venv\Scripts\python.exe" app.py --opaque %*
if exist "logs\start.ok" goto end
echo.
echo  Auch das hat nicht geklappt. Dritter Versuch im Browser ...
".venv\Scripts\python.exe" app.py --browser %*
if exist "logs\start.ok" goto end
echo.
echo  Start fehlgeschlagen. Die Fehlermeldung steht oben und in logs\absturz.log
pause
goto end

:setup_failed
echo.
echo  Die Einrichtung ist fehlgeschlagen. Die Meldung steht oben.
pause
exit /b 1

:end
endlocal
