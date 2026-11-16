#!/usr/bin/env python3
"""TikTok Factory – Desktop-App mit Liquid-Glass-Oberfläche.

Start:  python app.py
Die Kommandozeile der Pipeline gibt es weiterhin:  python make.py --help
"""
from __future__ import annotations

import argparse
import faulthandler
import logging
import sys
import traceback

from factory.app.desktop import launch
from factory.config import Config
from factory.errors import FactoryError
from factory.log import setup_logging


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="app.py", description="TikTok Factory als Desktop-App starten.")
    p.add_argument("--browser", action="store_true", help="im Standardbrowser statt im App-Fenster öffnen")
    p.add_argument("--opaque", action="store_true",
                   help="deckendes Fenster ohne Transparenz (falls dein System sie nicht sauber darstellt)")
    p.add_argument("--no-blur", action="store_true",
                   help="Windows: ohne Unschärfe hinter dem Fenster (Acrylic), nur klar durchscheinend")
    p.add_argument("--gui", choices=["qt", "gtk", "edgechromium", "cef"],
                   help="Fenster-Technik von pywebview erzwingen (Standard: automatisch)")
    p.add_argument("--port", type=int, default=0, help="fester Port für den lokalen Server (Standard: frei wählen)")
    p.add_argument("--no-open", action="store_true", help="im Browser-Modus die Adresse nur ausgeben")
    p.add_argument("--debug", action="store_true", help="Entwicklerwerkzeuge im Fenster, ausführliches Protokoll")
    args = p.parse_args(argv)
    try:
        cfg = Config()
    except FactoryError as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        return 2
    setup_logging(cfg.paths.logs, args.debug)
    # Abstürze festhalten – auch solche im Fenster-Unterbau, die kein Python-Fehler sind
    crash_log = open(cfg.paths.logs / "absturz.log", "w", encoding="utf-8")  # noqa: SIM115 – bleibt bis zum Ende offen
    faulthandler.enable(file=crash_log)
    try:
        return launch(cfg, browser=args.browser, opaque=args.opaque, gui=args.gui, debug=args.debug, port=args.port,
                      open_browser=not args.no_open, blur=not args.no_blur)
    except Exception:
        traceback.print_exc()
        traceback.print_exc(file=crash_log)
        logging.getLogger("app").exception("Die App ist mit einem Fehler beendet worden")
        return 3
    finally:
        crash_log.flush()


if __name__ == "__main__":
    sys.exit(main())
