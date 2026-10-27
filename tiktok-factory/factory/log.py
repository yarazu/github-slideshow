"""Logging: kompakt auf der Konsole, ausführlich in logs/factory_JJJJ-MM-TT.log."""
from __future__ import annotations

import logging
import sys
from datetime import datetime
from pathlib import Path

_NOISY = ("httpx", "httpx2", "httpcore", "urllib3", "anthropic", "faster_whisper", "PIL")


def setup_logging(log_dir: Path, verbose: bool = False) -> Path:
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"factory_{datetime.now():%Y-%m-%d}.log"

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG if verbose else logging.INFO)
    console.setFormatter(logging.Formatter("%(asctime)s  %(levelname)-7s %(message)s", "%H:%M:%S"))

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(name)s: %(message)s"))

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers[:] = [console, file_handler]
    for name in _NOISY:
        logging.getLogger(name).setLevel(logging.WARNING)
    return log_file
