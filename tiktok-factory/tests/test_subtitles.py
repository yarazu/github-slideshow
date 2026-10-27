import re

from factory.subtitles import (Word, align, build_ass, display_text, group_words, scene_spans,
                               script_tokens)


def heard_from(tokens, start=0.0, step=0.4):
    return [Word(t.text, start + i * step, start + i * step + 0.3) for i, t in enumerate(tokens)]


def test_tokens_carry_scenes_and_punctuation(script):
    tokens = script_tokens(script)
    assert tokens[0].scene == -1 and tokens[0].text == "Du"
    assert tokens[-1].scene == len(script.szenen) - 1
    assert any(t.sentence_end for t in tokens)
    assert display_text("Prozent,") == "Prozent"
    assert display_text("Seltsamste?") == "Seltsamste?"


def test_align_exact_match(script):
    tokens = script_tokens(script)
    words, ratio = align(tokens, heard_from(tokens))
    assert ratio == 1.0
    assert [w.text for w in words] == [t.text for t in tokens]
    assert all(b.start >= a.start for a, b in zip(words, words[1:]))


def test_align_handles_numbers_and_missing_words(script):
    tokens = script_tokens(script)
    heard = heard_from(tokens)
    heard[3] = Word("fünfundneunzig", heard[3].start, heard[3].end)   # "95" gesprochen als Wort
    del heard[10]                                                    # Whisper hat ein Wort verschluckt
    words, ratio = align(tokens, heard)
    assert len(words) == len(tokens)
    assert 0.9 < ratio < 1.0
    for a, b in zip(words, words[1:]):
        assert b.start > a.start and a.end <= b.start + 1e-9


def test_scene_spans_are_contiguous(script):
    tokens = script_tokens(script)
    words, _ = align(tokens, heard_from(tokens))
    spans = scene_spans(words, total=30.0)
    assert spans[0][0] == -1 and spans[0][1] == 0.0
    assert spans[-1][2] == 30.0
    for a, b in zip(spans, spans[1:]):
        assert a[2] == b[1]


def test_groups_have_one_to_three_words(script):
    tokens = script_tokens(script)
    words, _ = align(tokens, heard_from(tokens))
    groups = group_words(words, max_words=3, max_chars=16)
    assert all(1 <= len(g) <= 3 for g in groups)
    assert sum(len(g) for g in groups) == len(words)


def test_build_ass_highlights_active_word(cfg, script):
    tokens = script_tokens(script)
    words, _ = align(tokens, heard_from(tokens))
    ass = build_ass(words, cfg, hook_text=script.hook_overlay, total=20.0)
    assert "PlayResX: 1080" in ass and "PlayResY: 1920" in ass
    hook_lines = [l for l in ass.splitlines() if ",Hook," in l]
    assert len(hook_lines) == 1 and "0:00:00.00,0:00:02.00" in hook_lines[0]
    captions = [l for l in ass.splitlines() if ",Caption," in l]
    assert len(captions) == len(words)                     # ein Event pro aktivem Wort
    assert all(l.count("\\c&H35E1FF&") == 1 for l in captions)
    assert all(f"\\pos(540,{cfg.subtitles.position_y})" in l for l in captions)
    # Untertitel überlappen sich nie
    times = [re.match(r"Dialogue: 0,([^,]+),([^,]+),", l).groups() for l in captions]
    to_s = lambda t: sum(float(x) * m for x, m in zip(t.split(":"), (3600, 60, 1)))  # noqa: E731
    for (_s1, e1), (s2, _e2) in zip(times, times[1:]):
        assert to_s(e1) <= to_s(s2) + 1e-6


def test_long_words_are_scaled_to_fit(cfg, script):
    words = [Word("Donaudampfschifffahrtsgesellschaftskapitän", 0.0, 1.0, 0)]
    ass = build_ass(words, cfg, hook_text="", total=2.0)
    scale = int(re.search(r"\\fscx(\d+)\\fscy\d+\\t", ass).group(1))
    assert scale < 85 * 0.9  # deutlich verkleinert (Pop-in-Startwert ist 85 % der Zielgröße)


def test_hook_lines_are_balanced(cfg):
    from factory.subtitles import TextMeter, balanced_lines
    meter = TextMeter(cfg.paths.fonts / cfg.subtitles.font_file)
    lines = balanced_lines(meter, "3 HERZEN. BLAUES BLUT.", 140, 920)
    assert lines == ["3 HERZEN.", "BLAUES BLUT."]
    assert balanced_lines(meter, "KURZ", 140, 920) == ["KURZ"]
    assert balanced_lines(meter, "DONAUDAMPFSCHIFFFAHRTSGESELLSCHAFT", 140, 920) is None
