"""Fehlerklassen der Pipeline – jede Meldung ist für Menschen geschrieben."""


class FactoryError(Exception):
    """Erwartbarer Fehler mit verständlicher Meldung (wird ohne Traceback gezeigt)."""


class ConfigError(FactoryError):
    """Fehlende oder ungültige Konfiguration (.env, YAML, Keys, ffmpeg)."""


class ScriptError(FactoryError):
    """Skript konnte nicht erzeugt, geladen oder validiert werden."""


class TTSError(FactoryError):
    """Vertonung fehlgeschlagen."""


class SubtitleError(FactoryError):
    """Wort-Zeitstempel oder Untertitel fehlgeschlagen."""


class BrollError(FactoryError):
    """B-Roll-Suche oder -Download fehlgeschlagen."""


class RenderError(FactoryError):
    """ffmpeg-Verarbeitung fehlgeschlagen."""
