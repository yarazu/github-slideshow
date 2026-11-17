from datetime import datetime, timedelta

from factory.broll import pick_video_file, plan_shots
from factory.history import History
from factory.trends import TrendIdea, is_stale, mark_produced, parse_trends, pick_trends, write_trends


def test_plan_shots_respects_2_to_4_seconds(cfg, script):
    spans = [(-1, 0.0, 2.4), (0, 2.4, 3.6), (1, 3.6, 11.0), (2, 11.0, 18.7), (3, 18.7, 21.3)]
    shots = plan_shots(spans, script, cfg.niche("psychologie"), cfg)
    assert all(cfg.video.shot_min - 1e-6 <= s.duration <= cfg.video.shot_max + 1e-6 for s in shots)
    assert sum(s.frames for s in shots) == round(21.3 * cfg.video.fps)
    assert shots[0].start == 0.0 and shots[-1].end == 21.3
    assert shots[0].terms[0] == "sleeping woman"      # Hook-Suchbegriffe zuerst


def test_pick_video_file_prefers_smallest_covering_file():
    video = {"video_files": [
        {"file_type": "video/mp4", "width": 720, "height": 1280, "link": "a"},
        {"file_type": "video/mp4", "width": 1080, "height": 1920, "link": "b"},
        {"file_type": "video/mp4", "width": 2160, "height": 3840, "link": "c"},
    ]}
    assert pick_video_file(video, 1080, 1920)["link"] == "b"
    landscape = {"video_files": [{"file_type": "video/mp4", "width": 1920, "height": 1080, "link": "q"}]}
    assert pick_video_file(landscape, 1080, 1920)["link"] == "q"   # wird zugeschnitten + skaliert


def test_trends_roundtrip_and_selection(tmp_path):
    path = tmp_path / "trends.md"
    ideas = [TrendIdea(1, "Warum wir Träume sofort vergessen", "psychologie", "Anlass", "Q – https://x", "2026-10-27"),
             TrendIdea(2, "Warum Kürbisse leuchten", "geschichte", "Halloween", "Q – https://y", "2026-10-20")]
    now = datetime(2026, 10, 27, 12, 0)
    write_trends(path, ideas, now, "Test")
    researched, parsed = parse_trends(path)
    assert researched == now and [i.thema for i in parsed] == [i.thema for i in ideas]
    assert not is_stale(path, 24, now=now + timedelta(hours=5))
    assert is_stale(path, 24, now=now + timedelta(hours=25))

    history = History(tmp_path / "h.json")
    history.add({"thema": "Warum vergessen wir Träume so schnell"})
    picked = pick_trends(path, history, 2)
    assert [i.nr for i in picked] == [2]                 # Idee 1 gab es schon

    mark_produced(path, parsed[1], "2026-10-27_kuerbisse")
    _, after = parse_trends(path)
    assert after[1].status.startswith("produziert") and after[0].is_open


def test_pixabay_results_look_like_pexels(tmp_path, monkeypatch):
    from factory import broll

    class Resp:
        status_code = 200
        text = ""

        def __init__(self, payload):
            self.payload = payload

        def json(self):
            return self.payload

    calls = []
    video_hits = {"hits": [
        {"id": 1, "pageURL": "https://pixabay.com/videos/a-1/", "duration": 12, "user": "anna", "user_id": 7,
         "videos": {"large": {"url": "", "width": 0, "height": 0},            # leer: wird übersprungen
                    "medium": {"url": "https://cdn/v1m.mp4", "width": 1080, "height": 1920},
                    "small": {"url": "https://cdn/v1s.mp4", "width": 720, "height": 1280}}},
        {"id": 2, "pageURL": "https://pixabay.com/videos/b-2/", "duration": 30, "user": "ben", "user_id": 8,
         "videos": {"large": {"url": "https://cdn/v2l.mp4", "width": 1920, "height": 1080}}},
    ]}
    photo_hits = {"hits": [{"id": 5, "pageURL": "https://pixabay.com/photos/c-5/", "user": "cara", "user_id": 9,
                            "largeImageURL": "https://cdn/p5.jpg"}]}

    def fake_request(method, url, **kwargs):
        calls.append((url, kwargs["params"]))
        return Resp(video_hits if "/videos/" in url else photo_hits)

    monkeypatch.setattr(broll, "http_request", fake_request)
    px = broll.PixabayClient("k", tmp_path)
    portrait = px.search_videos("ocean", "portrait")
    assert [v["id"] for v in portrait] == [1]                                         # Querformat aussortiert
    assert [f["id"] for f in portrait[0]["video_files"]] == ["medium", "small"]
    assert broll.pick_video_file(portrait[0], 1080, 1920)["link"] == "https://cdn/v1m.mp4"
    assert portrait[0]["user"] == {"name": "anna", "url": "https://pixabay.com/users/anna-7/"}
    assert len(px.search_videos("ocean", None)) == 2
    assert len(calls) == 1                                                            # zweite Suche aus dem Cache
    assert calls[0][1]["key"] == "k" and calls[0][1]["safesearch"] == "true"
    photo = px.search_photos("ocean")[0]
    assert photo["src"]["original"] == "https://cdn/p5.jpg" and photo["photographer"] == "cara"
