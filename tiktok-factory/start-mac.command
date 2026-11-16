#!/bin/bash
# TikTok Factory starten (macOS, Doppelklick). Beim ersten Mal wird die Python-Umgebung eingerichtet.
cd "$(dirname "$0")" || exit 1
if [ ! -x .venv/bin/python ]; then
  echo "Erste Einrichtung: Python-Umgebung wird angelegt ..."
  python3 -m venv .venv || { echo "Python 3.11+ fehlt (python3)."; read -r -p "Enter zum Schließen"; exit 1; }
fi
if ! cmp -s requirements.txt .venv/requirements.installiert; then
  echo "Pakete werden installiert (dauert beim ersten Mal einige Minuten) ..."
  .venv/bin/python -m pip install -q --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt || { read -r -p "Einrichtung fehlgeschlagen – Enter zum Schließen"; exit 1; }
  cp requirements.txt .venv/requirements.installiert
fi
command -v ffmpeg >/dev/null || echo "Hinweis: ffmpeg fehlt (brew install ffmpeg)."
.venv/bin/python app.py "$@"
[ -f logs/start.ok ] || { echo "Start ohne Transparenz ..."; .venv/bin/python app.py --opaque "$@"; }
[ -f logs/start.ok ] || { echo "Start im Browser ..."; .venv/bin/python app.py --browser "$@"; }
