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
