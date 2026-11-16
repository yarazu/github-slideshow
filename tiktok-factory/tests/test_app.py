"""Desktop-App ohne Fenster prüfen: lokaler Server, Auftragswarteschlange, Glas-Karte."""
import json
import shutil
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest
from PIL import Image

from factory import media
from factory.app import jobs as jobs_module
from factory.app.server import AppServer
from factory.config import Config
from factory.errors import Cancelled
from factory.overlay import composite, text_card

ROOT = Path(__file__).resolve().parent.parent
KEYS = ("ANTHROPIC_API_KEY", "FACTORY_ANTHROPIC_API_KEY", "AZURE_SPEECH_KEY", "PEXELS_API_KEY",
        "ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID", "TTS_PROVIDER")


@pytest.fixture
def app(tmp_path, monkeypatch):
    """Server auf einer Kopie des Projekts (eigene .env, eigener Ausgabeordner)."""
    for key in KEYS:
        monkeypatch.delenv(key, raising=False)
    shutil.copytree(ROOT / "config", tmp_path / "config")
    shutil.copytree(ROOT / "ui", tmp_path / "ui")
    shutil.copytree(ROOT / "assets" / "fonts", tmp_path / "assets" / "fonts")
    (tmp_path / "data").mkdir()
    shutil.copy(ROOT / "data" / "trends.md", tmp_path / "data" / "trends.md")
    server = AppServer(Config(tmp_path))
    server.start()
    yield server
    server.stop()


def call(server, path, body=None, token=True, headers=None, raw=None):
    req = urllib.request.Request(f"http://127.0.0.1:{server.port}{path}", headers=headers or {})
    if token:
        req.add_header("X-Factory-Token", server.token)
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    if raw is not None:
        req.data = raw
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=10) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as err:
        return err.code, err.read(), dict(err.headers)


def data(result):
    return json.loads(result[1])


def wait_done(server, timeout=10.0):
    end = time.time() + timeout
    while server.jobs.busy():
        assert time.time() < end, "Auftrag wurde nicht fertig"
        time.sleep(0.02)
    return server.jobs.snapshot()["jobs"]


# --- Sicherheit ---------------------------------------------------------------------------
def test_page_and_api_need_the_session_token(app):
    assert call(app, "/", token=False)[0] == 403
    assert call(app, "/api/state", token=False)[0] == 403
    status, body, headers = call(app, f"/?t={app.token}", token=False)
    assert status == 200 and app.token.encode() in body
    assert "frame-ancestors 'none'" in headers["Content-Security-Policy"]
    assert call(app, f"/?t={app.token}", token=False, headers={"Host": "evil.example"})[0] == 403


def test_static_files_cannot_escape_the_ui_folder(app):
    assert call(app, "/ui/app.css", token=False)[0] == 200
    assert call(app, "/ui/..%2fconfig%2fsettings.yaml", token=False)[0] == 404
    assert call(app, "/ui/../config/settings.yaml", token=False)[0] == 404
    assert call(app, "/fonts/Poppins-Black.ttf", token=False)[0] == 200
    assert call(app, "/fonts/OFL-Poppins.txt", token=False)[0] == 404


def test_secrets_are_written_but_never_returned(app):
    key = "sk-test-geheim-1234"
    status, body, _ = call(app, "/api/settings", {"values": {"ANTHROPIC_API_KEY": key, "TTS_PROVIDER": "elevenlabs"}})
    assert status == 200 and key.encode() not in body
    view = json.loads(body)["settings"]
    assert view["ANTHROPIC_API_KEY"] == {"kind": "secret", "set": True, "hint": "…1234"}
    assert view["TTS_PROVIDER"]["value"] == "elevenlabs"
    assert key in (app.cfg.paths.root / ".env").read_text()
    assert key.encode() not in call(app, "/api/bootstrap")[1]
    assert call(app, "/api/settings", {"values": {"PATH": "x"}})[0] == 400          # nur erlaubte Felder
    assert call(app, "/api/settings", {"values": {"ANTHROPIC_MODEL": "a\nB=1"}})[0] == 400
    call(app, "/api/settings", {"values": {"ANTHROPIC_API_KEY": ""}})                # leer = unverändert
    assert data(call(app, "/api/settings"))["settings"]["ANTHROPIC_API_KEY"]["set"] is True


# --- Daten für die Oberfläche -----------------------------------------------------------------
def test_bootstrap_has_everything_the_ui_needs(app):
    boot = data(call(app, "/api/bootstrap"))
    assert {n["key"] for n in boot["niches"]} >= {"psychologie", "trend"}
    assert len(boot["trends"]["ideen"]) == 10 and boot["trends"]["ideen"][0]["quelle_url"].startswith("http")
    assert boot["system"]["ffmpeg"]["ok"] and boot["system"]["font"]
    assert boot["prefs"]["theme"] == "dark" and boot["library"] == []
    prefs = data(call(app, "/api/prefs", {"glass": 250, "theme": "light", "fremd": 1}))["prefs"]
    assert prefs["glass"] == 100 and prefs["theme"] == "light" and "fremd" not in prefs


def test_library_and_media_with_range_requests(app):
    folder = app.cfg.paths.output / "2026-11-16_test"
    folder.mkdir(parents=True)
    (folder / "video.mp4").write_bytes(bytes(range(200)))
    (folder / "meta.json").write_text(json.dumps({"titel": "Test", "dauer_s": 66.0, "hinweise": ["a"]}))
    (folder / "beschreibung.txt").write_text("Text\n\n#a #b")
    items = data(call(app, "/api/library"))["items"]
    assert items == [{**items[0], "folder": folder.name, "kind": "video", "titel": "Test", "hinweise": 1}]
    assert data(call(app, f"/api/library/item?folder={folder.name}"))["beschreibung"].startswith("Text")

    url = f"/media/{folder.name}/video.mp4"
    assert call(app, url, token=False)[0] == 403                                   # ohne Token kein Medium
    status, body, headers = call(app, f"{url}?t={app.token}", token=False, headers={"Range": "bytes=10-19"})
    assert status == 206 and body == bytes(range(10, 20)) and headers["Content-Range"] == "bytes 10-19/200"
    assert call(app, f"{url}?t={app.token}", token=False, headers={"Range": "bytes=-5"})[1] == bytes(range(195, 200))
    assert call(app, f"{url}?t={app.token}", token=False, headers={"Range": "bytes=500-"})[0] == 416
    assert call(app, f"/media/{folder.name}/meta.json?t={app.token}", token=False)[0] == 404
    assert call(app, f"/media/..%2f..%2fconfig/video.mp4?t={app.token}", token=False)[0] in (400, 404)


def test_upload_rejects_non_audio(app):
    assert call(app, "/api/upload?name=x.exe", raw=b"MZ")[0] == 400
    assert call(app, "/api/upload?name=x.mp3", raw=b"kein audio")[0] == 400         # ffprobe kann es nicht lesen
    assert not list((app.cfg.paths.work / "uploads").glob("*"))


# --- Aufträge ---------------------------------------------------------------------------------
def test_submit_without_keys_explains_what_is_missing(app):
    status, body, _ = call(app, "/api/jobs", {"mode": "niche", "niche": "psychologie", "count": 2})
    assert status == 400
    assert "ANTHROPIC_API_KEY" in data((status, body))["error"] and "AZURE_SPEECH_KEY" in data((status, body))["error"]
    assert call(app, "/api/jobs", {"mode": "quatsch"})[0] == 400


SCRIPT = {"titel": "Drei Herzen", "hook": "Ein Oktopus hat drei Herzen.",
          "szenen": [{"text": "Zwei pumpen Blut durch die Kiemen.", "pexels_suchbegriffe": ["octopus"]}]}


def fake_pipeline(monkeypatch, behaviour):
    class FakePipeline:
        def __init__(self, cfg, history, options, progress):
            self.cfg, self.progress = cfg, progress

        def run(self, job):
            return behaviour(self, job)

    monkeypatch.setattr(jobs_module, "Pipeline", FakePipeline)
    monkeypatch.setattr(jobs_module, "required_keys", lambda *a, **k: [])


def test_job_reports_stages_and_finishes(app, monkeypatch, caplog):
    caplog.set_level("INFO")          # wie in der App (setup_logging)
    seen = []

    def run(pipeline, job):
        for key in ("stimme", "timing", "broll", "schnitt", "ton", "render", "abschluss"):
            pipeline.progress.stage(key, key)
            pipeline.progress.step(0.5, "halb")
            seen.append(app.jobs.snapshot()["jobs"][0]["percent"])
        out = pipeline.cfg.paths.output / "fertig"
        out.mkdir(parents=True)
        return out

    fake_pipeline(monkeypatch, run)
    ids = data(call(app, "/api/jobs", {"mode": "script", "script": SCRIPT, "niche": "tiere"}))["ids"]
    job = wait_done(app)[0]
    assert job["id"] == ids[0] and job["status"] == "fertig" and job["percent"] == 100 and job["output"] == "fertig"
    assert job["title"] == "Drei Herzen" and job["niche"] == "tiere"
    assert seen == sorted(seen) and 0 < seen[0] < seen[-1] < 100                     # Fortschritt läuft nur vorwärts
    states = {s["key"]: s["state"] for s in job["stages"]}
    assert states["recherche"] == "skipped" and states["render"] == "done"
    assert any("Fertig" in line["msg"] for line in app.jobs.snapshot()["log"])


def test_running_job_can_be_cancelled(app, monkeypatch):
    def run(pipeline, job):
        pipeline.progress.stage("schnitt")
        for _ in range(400):
            time.sleep(0.01)
            pipeline.progress.step(0.1)      # prüft bei jedem Schritt, ob abgebrochen wurde
        raise AssertionError("hätte abbrechen müssen")

    fake_pipeline(monkeypatch, run)
    first = data(call(app, "/api/jobs", {"mode": "script", "script": SCRIPT}))["ids"][0]
    second = data(call(app, "/api/jobs", {"mode": "script", "script": SCRIPT}))["ids"][0]
    while app.jobs.snapshot()["running"] != first:
        time.sleep(0.01)
    assert data(call(app, "/api/jobs/cancel", {}))["cancelled"] == 2                 # laufender + wartender
    by_id = {j["id"]: j for j in wait_done(app)}
    assert by_id[first]["status"] == "abgebrochen" and by_id[second]["status"] == "abgebrochen"
    media.check_cancel()                                                             # Abbruch-Merker ist zurückgesetzt
    call(app, "/api/jobs/clear", {})
    assert app.jobs.snapshot()["jobs"] == []


def test_failed_job_keeps_its_error_message(app, monkeypatch):
    def run(pipeline, job):
        pipeline.progress.stage("stimme")
        raise jobs_module.ConfigError("Azure Speech: Key ungültig")

    fake_pipeline(monkeypatch, run)
    call(app, "/api/jobs", {"mode": "script", "script": SCRIPT})
    job = wait_done(app)[0]
    assert job["status"] == "fehler" and "Key ungültig" in job["error"]
    assert {s["key"]: s["state"] for s in job["stages"]}["stimme"] == "error"


def test_ffmpeg_stops_when_cancel_is_requested():
    media.request_cancel()
    with pytest.raises(Cancelled):
        media.run_ffmpeg(["-f", "lavfi", "-i", "testsrc=d=1", "-f", "null", "-"], "Test")
    media.clear_cancel()
    seconds = []
    media.run_ffmpeg(["-f", "lavfi", "-i", "testsrc=d=1:r=30", "-f", "null", "-"], "Test", on_progress=seconds.append)
    assert seconds and 0.9 < seconds[-1] <= 1.0


# --- Glas-Karte ---------------------------------------------------------------------------------
def test_glass_card_fits_the_frame_and_is_translucent():
    cfg = Config(ROOT)
    card = text_card("3 Herzen. Blaues Blut. 🐙", cfg, center_y=cfg.subtitles.hook_position_y)
    assert card.w % 2 == 0 and card.h % 2 == 0 and card.x % 2 == 0 and card.y % 2 == 0    # gerade Werte für yuv420
    assert card.x >= cfg.glass.margin and card.x + card.w <= cfg.video.width - cfg.glass.margin
    assert card.mask.size == (card.w, card.h) and card.mask.getpixel((0, 0)) == 0            # runde Ecken
    assert card.mask.getpixel((card.w // 2, card.h // 2)) == 255
    alpha = card.panel.getchannel("A")
    assert alpha.getpixel((2, 2)) == 0                                                       # außen leer
    assert 40 < alpha.getpixel((card.pad + card.w // 2, card.pad + 12)) < 235                # Glas ist durchscheinend
    long = text_card("Ein sehr langer Hook mit vielen Wörtern der trotzdem ins Bild passen muss", cfg, center_y=470)
    assert long.x + long.w <= cfg.video.width
    frame = Image.new("RGB", (cfg.video.width, cfg.video.height), (200, 60, 40))
    out = composite(frame, card, cfg.glass.blur)
    assert out.size == frame.size and out.getpixel((10, 10)) == (200, 60, 40)                # außerhalb unverändert
    assert out.getpixel((card.x + 30, card.y + card.h // 2)) != (200, 60, 40)
