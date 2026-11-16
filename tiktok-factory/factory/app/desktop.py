"""Das App-Fenster: rahmenlos und durchscheinend (pywebview). Ohne pywebview läuft die App im Browser.

Transparenz je System:
  * macOS         – echtes System-Glas: der Desktop hinter dem Fenster wird unscharf (Vibrancy)
  * Windows/Linux – durchscheinendes Fenster; die Oberfläche tönt selbst ab, damit Text lesbar bleibt
  * --opaque      – deckendes Fenster mit eigenem Farbhintergrund (falls Transparenz Probleme macht)
"""
from __future__ import annotations

import logging
import sys
import time
import webbrowser

from ..config import Config
from .server import AppServer, load_prefs, save_prefs

log = logging.getLogger("app")

SIZE = (1240, 800)
MIN_SIZE = (980, 660)
COMPACT_SIZE = (620, 236)


class WindowApi:
    """Was die Oberfläche am Fenster steuern darf (window.pywebview.api.*)."""

    def __init__(self, cfg: Config):
        self._cfg = cfg
        self._window = None
        self._maximized = False
        self._normal_size = SIZE

    def _bind(self, window) -> None:
        self._window = window

    def close(self) -> None:
        self._window.destroy()

    def minimize(self) -> None:
        self._window.minimize()

    def toggle_maximize(self) -> bool:
        if self._maximized:
            self._window.restore()
        else:
            self._window.maximize()
        self._maximized = not self._maximized
        return self._maximized

    def resize(self, width: int, height: int) -> None:
        """Für den Ziehgriff unten rechts (rahmenlose Fenster haben unter Windows/Linux keinen Rand)."""
        self._window.resize(max(MIN_SIZE[0], int(width)), max(MIN_SIZE[1], int(height)))

    def set_on_top(self, value: bool) -> bool:
        self._window.on_top = bool(value)
        save_prefs(self._cfg, {"on_top": bool(value)})
        return bool(value)

    def set_compact(self, compact: bool) -> bool:
        """Mini-Overlay: kleine schwebende Leiste, immer im Vordergrund."""
        if compact:
            if self._maximized:
                self.toggle_maximize()
            self._normal_size = (self._window.width, self._window.height)
            self._window.resize(*COMPACT_SIZE)
            self._window.on_top = True
        else:
            self._window.resize(*self._normal_size)
            self._window.on_top = bool(load_prefs(self._cfg).get("on_top"))
        return bool(compact)


def _serve_in_browser(server: AppServer, open_browser: bool) -> int:
    print(f"\nTikTok Factory läuft im Browser:\n  {server.url}\n(Beenden mit Strg+C)\n")
    if open_browser:
        webbrowser.open(server.url)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("Beendet.")
    finally:
        server.stop()
    return 0


def windows_acrylic(window) -> bool:
    """Windows 10/11: Desktop hinter dem Fenster unscharf stellen (Acrylic) + runde Ecken (Windows 11).

    Nutzt SetWindowCompositionAttribute – dieselbe (undokumentierte) Schnittstelle wie viele Acrylic-Apps.
    Gibt False zurück, wenn Windows den Aufruf ablehnt; die Oberfläche fällt dann auf „klar“ zurück.
    """
    import ctypes
    from ctypes import wintypes

    class Accent(ctypes.Structure):
        _fields_ = [("state", ctypes.c_int), ("flags", ctypes.c_int), ("color", ctypes.c_uint),
                    ("animation", ctypes.c_int)]

    class Data(ctypes.Structure):
        _fields_ = [("attribute", ctypes.c_int), ("data", ctypes.c_void_p), ("size", ctypes.c_size_t)]

    hwnd = wintypes.HWND(int(window.native.Handle.ToInt64()))
    accent = Accent(4, 2, 0x55140D0B, 0)  # 4 = Acrylic; Farbe AABBGGRR: dunkle Tönung, 33 % deckend
    data = Data(19, ctypes.addressof(accent), ctypes.sizeof(accent))  # 19 = WCA_ACCENT_POLICY
    user32 = ctypes.windll.user32
    user32.SetWindowCompositionAttribute.argtypes = [wintypes.HWND, ctypes.POINTER(Data)]
    user32.SetWindowCompositionAttribute.restype = wintypes.BOOL
    ok = bool(user32.SetWindowCompositionAttribute(hwnd, ctypes.byref(data)))
    try:  # Windows 11: runde Fensterecken (33 = DWMWA_WINDOW_CORNER_PREFERENCE, 2 = rund)
        corner = ctypes.c_int(2)
        ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 33, ctypes.byref(corner), ctypes.sizeof(corner))
    except (AttributeError, OSError):
        pass
    return ok


def _apply_acrylic(window) -> None:
    try:
        ok = windows_acrylic(window)
    except Exception as exc:  # ältere Windows-Version, anderes Fenster-Backend …
        log.debug("Acrylic nicht möglich: %s", exc)
        ok = False
    if not ok:
        log.warning("Windows-Unschärfe (Acrylic) ließ sich nicht einschalten – Fenster bleibt klar durchscheinend.")
        window.evaluate_js("window.setBackdrop && window.setBackdrop('clear')")


def launch(cfg: Config, *, browser: bool = False, opaque: bool = False, gui: str | None = None,
           debug: bool = False, port: int = 0, open_browser: bool = True, blur: bool = True) -> int:
    prefs = load_prefs(cfg)
    webview = None
    if not browser:
        try:
            import webview  # type: ignore[no-redef]
        except ImportError:
            log.warning("pywebview ist nicht installiert (pip install -r requirements.txt) – öffne im Browser.")
    if webview is None:
        return _serve_in_browser(_started(AppServer(cfg, port=port)), open_browser)

    transparent = not opaque and bool(prefs.get("transparent", True))
    vibrancy = transparent and sys.platform == "darwin"
    acrylic = transparent and sys.platform == "win32" and blur and bool(prefs.get("blur", True))
    shell = {"mode": "desktop", "platform": sys.platform,
             "backdrop": "vibrancy" if vibrancy else "acrylic" if acrylic else "clear" if transparent else "opaque"}
    server = _started(AppServer(cfg, port=port, shell=shell))
    api = WindowApi(cfg)
    if "DRAG_REGION_DIRECT_TARGET_ONLY" in webview.settings:
        webview.settings["DRAG_REGION_DIRECT_TARGET_ONLY"] = True  # Knöpfe in der Titelleiste bleiben klickbar
    window = webview.create_window(
        "TikTok Factory", server.url, js_api=api, width=SIZE[0], height=SIZE[1],
        min_size=COMPACT_SIZE,  # das Mini-Overlay ist kleiner als das normale Fenster
        frameless=True, easy_drag=False, transparent=transparent, vibrancy=vibrancy,
        background_color="#0B0D14", text_select=True, on_top=bool(prefs.get("on_top")))
    api._bind(window)
    if acrylic:
        window.events.loaded += lambda *_: _apply_acrylic(window)
    failed: list[Exception] = []
    try:
        webview.start(gui=gui, debug=debug)
    except Exception as exc:  # kein Fenster-Backend (häufig unter Linux ohne GTK/Qt)
        failed.append(exc)
    if failed:
        log.warning("Das App-Fenster konnte nicht geöffnet werden (%s) – öffne im Browser.", failed[0])
        server.shell.update({"mode": "browser", "backdrop": "opaque"})
        return _serve_in_browser(server, open_browser)
    server.stop()
    return 0


def _started(server: AppServer) -> AppServer:
    server.start()
    return server


def wait_until_idle(server: AppServer, poll: float = 0.25) -> None:
    """Hilfsfunktion für Tests: blockiert, bis keine Aufträge mehr laufen."""
    while server.jobs.busy():
        time.sleep(poll)
