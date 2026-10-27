"""ffmpeg-Rendering: Shots (9:16-Crop + leichter Zoom), Tonmischung, Lautheit, Endvideo."""
from __future__ import annotations

import logging
import os
import random
from pathlib import Path

from . import media
from .broll import Shot
from .config import Config
from .errors import RenderError

log = logging.getLogger(__name__)

AUDIO_EXT = {".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac"}

# Rückfall-Farbverläufe (dunkel, damit weiße Untertitel lesbar bleiben)
_GRADIENTS = [("0x0f2027", "0x2c5364"), ("0x1d2b64", "0x6a3093"), ("0x232526", "0x414345"),
              ("0x141e30", "0x243b55"), ("0x200122", "0x6f0000")]


def _encode_args(cfg: Config) -> list:
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p",
            "-r", cfg.video.fps, "-an"]


def render_shot(shot: Shot, out: Path, cfg: Config, *, loop: bool = False) -> Path:
    """Ein Shot als Zwischenclip: exakt shot.frames Bilder, 1080×1920, 30 fps."""
    W, H, fps, n = cfg.video.width, cfg.video.height, cfg.video.fps, shot.frames
    asset = shot.media
    if n <= 0:
        raise RenderError(f"Shot {shot.index} hat keine Länge")
    variant = shot.index % 4
    if asset is None or asset.kind == "color":
        c0, c1 = _GRADIENTS[shot.index % len(_GRADIENTS)]
        src = f"gradients=s={W}x{H}:r={fps}:c0={c0}:c1={c1}:speed=0.01:seed={shot.index}"
        args = ["-f", "lavfi", "-i", src, "-vf", "format=yuv420p"]
    elif asset.kind == "video":
        z = cfg.video.zoom_video
        z_expr = f"1+{z}*on/{n}" if variant % 2 == 0 else f"{1 + z}-{z}*on/{n}"
        avail = asset.duration or 0.0
        need = n / fps
        offset = max(0.0, min(avail - need - 0.3, avail * 0.25)) if avail > need + 0.3 else 0.0
        vf = (f"fps={fps},scale={W}:{H}:force_original_aspect_ratio=increase:flags=lanczos,crop={W}:{H},"
              f"setsar=1,zoompan=z='{z_expr}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s={W}x{H}:fps={fps},"
              "format=yuv420p")
        loop_args = ["-stream_loop", "-1"] if loop or avail < need + 0.1 else []
        args = [*loop_args, "-ss", f"{offset:.2f}", "-i", asset.path, "-vf", vf]
    else:  # Foto: Ken Burns, in doppelter Auflösung berechnet (kein Ruckeln)
        z = cfg.video.zoom_photo
        moves = [
            (f"1+{z}*on/{n}", "iw/2-(iw/zoom/2)", "ih/2-(ih/zoom/2)"),            # rein
            (f"{1 + z}-{z}*on/{n}", "iw/2-(iw/zoom/2)", "ih/2-(ih/zoom/2)"),      # raus
            (f"{1 + z}", f"(iw-iw/zoom)*on/{n}", "ih/2-(ih/zoom/2)"),             # Schwenk →
            (f"{1 + z}", "iw/2-(iw/zoom/2)", f"(ih-ih/zoom)*(1-on/{n})"),         # Schwenk ↑
        ]
        zx, xx, yx = moves[variant]
        vf = (f"scale={2 * W}:{2 * H}:force_original_aspect_ratio=increase:flags=lanczos,crop={2 * W}:{2 * H},"
              f"setsar=1,zoompan=z='{zx}':x='{xx}':y='{yx}':d=1:s={W}x{H}:fps={fps},format=yuv420p")
        args = ["-loop", "1", "-framerate", fps, "-i", asset.path, "-vf", vf]
    media.run_ffmpeg([*args, "-frames:v", n, *_encode_args(cfg), out], f"Shot {shot.index:02d} rendern")
    got = round(media.duration(out) * fps)
    if got < n:
        if asset is not None and asset.kind == "video" and not loop:
            return render_shot(shot, out, cfg, loop=True)
        raise RenderError(f"Shot {shot.index}: nur {got} statt {n} Bilder erzeugt")
    return out


def render_shots(shots: list[Shot], work_dir: Path, cfg: Config) -> Path:
    """Rendert alle Shots und schreibt die Concat-Liste. Gibt den Pfad der Liste zurück."""
    lines = []
    for shot in shots:
        out = work_dir / f"shot_{shot.index:03d}.mp4"
        render_shot(shot, out, cfg)
        lines.append(f"file '{out.name}'")
    concat = work_dir / "shots.txt"
    concat.write_text("\n".join(lines) + "\n", encoding="utf-8")
    log.info("%d Shots gerendert", len(shots))
    return concat


# --------------------------------------------------------------------------------------
# Ton
# --------------------------------------------------------------------------------------
def choose_music(cfg: Config, mood: str, avoid: set[str], rng: random.Random) -> Path | None:
    folder = cfg.paths.music / mood
    tracks = sorted(p for p in folder.iterdir() if p.suffix.lower() in AUDIO_EXT) if folder.is_dir() else []
    if not tracks and cfg.paths.music.is_dir():
        tracks = sorted(p for p in cfg.paths.music.rglob("*") if p.suffix.lower() in AUDIO_EXT)
        if tracks:
            log.info("Kein Track in assets/music/%s/ – nehme einen aus assets/music/", mood)
    if not tracks:
        log.warning("Keine Musik in assets/music/ gefunden – Video ohne Hintergrundmusik.")
        return None
    return rng.choice([t for t in tracks if t.name not in avoid] or tracks)


def build_audio(voice: Path, music: Path | None, total: float, work_dir: Path, cfg: Config,
                rng: random.Random) -> dict:
    """Stimme + geduckte Musik mischen, dann 2-Pass-loudnorm auf Ziel-LUFS."""
    a = cfg.audio
    loud = dict(target_lufs=a.target_lufs, true_peak=a.true_peak, lra=a.lra)
    voice_i = media.measure_loudness(voice, **loud)["input_i"]
    mix = work_dir / "mix.wav"
    info: dict = {"musik": None}
    stereo = "aformat=sample_rates=48000:channel_layouts=stereo"
    if music is not None:
        music_i = media.measure_loudness(music, **loud).get("input_i", float("-inf"))
        if music_i == float("-inf") or music_i < -70:
            log.warning("Musiktrack %s ist stumm – ohne Musik weiter.", music.name)
            music = None
    if music is not None:
        music_len = media.duration(music)
        gain = (voice_i - a.music_below_voice_db) - music_i
        offset = rng.uniform(0, music_len - total - 1) if music_len > total + 6 else 0.0
        loop = ["-stream_loop", "-1"] if music_len < total + offset + 0.5 else []
        fade_out_at = max(0.0, total - a.music_fade_out)
        graph = (f"[0:a]{stereo},apad=whole_dur={total:.3f}[v];"
                 f"[1:a]{stereo},atrim=start={offset:.2f},asetpts=PTS-STARTPTS,atrim=duration={total:.3f},"
                 f"volume={gain:.2f}dB,afade=t=in:st=0:d={a.music_fade_in},"
                 f"afade=t=out:st={fade_out_at:.3f}:d={a.music_fade_out}[m];"
                 "[v][m]amix=inputs=2:duration=first:normalize=0[out]")
        media.run_ffmpeg(["-i", voice, *loop, "-i", music, "-filter_complex", graph, "-map", "[out]",
                          "-c:a", "pcm_s16le", mix], "Stimme und Musik mischen")
        info = {"musik": music.name, "musik_pegel_db": round(gain, 1), "musik_start_s": round(offset, 1),
                "musik_unter_stimme_db": a.music_below_voice_db}
        log.info("Musik: %s (%.1f dB → %d dB unter der Stimme)", music.name, gain, a.music_below_voice_db)
    else:
        media.run_ffmpeg(["-i", voice, "-af", f"{stereo},apad=whole_dur={total:.3f}", "-c:a", "pcm_s16le", mix],
                         "Stimme aufbereiten")
    m = media.measure_loudness(mix, **loud)
    final = work_dir / "audio.wav"
    loudnorm = (f"loudnorm=I={a.target_lufs}:TP={a.true_peak}:LRA={a.lra}:measured_I={m['input_i']}:"
                f"measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:"
                f"offset={m['target_offset']}:linear=true,aresample=48000")
    media.run_ffmpeg(["-i", mix, "-af", loudnorm, "-c:a", "pcm_s16le", "-ar", "48000", final],
                     "Lautheit normalisieren")
    result = media.measure_loudness(final, **loud)
    info.update({"lufs": round(result["input_i"], 1), "true_peak_db": round(result["input_tp"], 1)})
    log.info("Lautheit: %.1f LUFS, True Peak %.1f dBTP", result["input_i"], result["input_tp"])
    info["datei"] = final
    return info


# --------------------------------------------------------------------------------------
# Endvideo
# --------------------------------------------------------------------------------------
def final_render(concat_list: Path, audio: Path, ass_file: Path, out: Path, total: float, cfg: Config) -> Path:
    work_dir = concat_list.parent
    fonts = os.path.relpath(cfg.paths.fonts, work_dir).replace(os.sep, "/")
    args = [
        "-f", "concat", "-safe", "0", "-i", concat_list.name,
        "-i", audio.name,
        "-map", "0:v:0", "-map", "1:a:0",
        "-vf", f"ass={ass_file.name}:fontsdir={fonts}",
        "-c:v", "libx264", "-preset", cfg.video.preset, "-crf", cfg.video.crf,
        "-profile:v", "high", "-level:v", "4.1", "-pix_fmt", "yuv420p", "-r", cfg.video.fps,
        "-g", cfg.video.fps * 2,
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        "-t", f"{total:.3f}", "-movflags", "+faststart",
        out.resolve(),
    ]
    media.run_ffmpeg(args, "Endvideo rendern", cwd=work_dir)
    return out


def verify_video(path: Path, cfg: Config) -> dict:
    """Prüft das fertige Video gegen die TikTok-Vorgaben."""
    info = media.probe(path)
    video = next((s for s in info["streams"] if s["codec_type"] == "video"), None)
    audio = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    dur = float(info["format"]["duration"])
    problems = []
    if not video or video.get("codec_name") != "h264":
        problems.append("Videospur ist nicht H.264")
    elif (video["width"], video["height"]) != (cfg.video.width, cfg.video.height):
        problems.append(f"Auflösung {video['width']}×{video['height']}")
    elif video.get("avg_frame_rate") not in (f"{cfg.video.fps}/1", str(cfg.video.fps)):
        problems.append(f"Bildrate {video.get('avg_frame_rate')}")
    if not audio or audio.get("codec_name") != "aac":
        problems.append("Tonspur ist nicht AAC")
    if not cfg.duration.min_hard <= dur <= cfg.duration.max_hard:
        problems.append(f"Dauer {dur:.1f} s außerhalb {cfg.duration.min_hard}–{cfg.duration.max_hard} s")
    if problems:
        raise RenderError("Endvideo entspricht nicht den Vorgaben: " + "; ".join(problems))
    return {"dauer_s": round(dur, 2), "aufloesung": f"{video['width']}x{video['height']}",
            "fps": cfg.video.fps, "video_codec": "h264", "audio_codec": "aac",
            "groesse_mb": round(int(info["format"]["size"]) / 1e6, 1)}


def extract_frame(video: Path, t: float, out: Path) -> Path:
    media.run_ffmpeg(["-ss", f"{t:.3f}", "-i", video, "-frames:v", "1", "-q:v", "2", out], f"Bild bei {t:.1f}s")
    return out
