"""Skripte: Themenideen, Faktenrecherche, Schreiben, Regelprüfung, Verlängern/Kürzen."""
from __future__ import annotations

import json
import logging
import math
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .config import Config, Niche
from .errors import ScriptError
from .history import History, similar
from .llm import LLM, Research
from .utils import HttpError, count_words, http_request

log = logging.getLogger(__name__)

HOOK_MAX_WORDS = 12
SCENE_MAX_WORDS = 35
_GREETING = re.compile(
    r"^\W*(hallo|hey|hi|servus|moin|willkommen|heute|in diesem video|hello|welcome|today|in this video)\b", re.I)
_HASHTAG = re.compile(r"#[\wäöüß]+")


# --------------------------------------------------------------------------------------
# Datenmodell
# --------------------------------------------------------------------------------------
@dataclass
class Scene:
    text: str
    pexels_suchbegriffe: list[str] = field(default_factory=list)


@dataclass
class Source:
    fakt: str
    quelle: str
    url: str


@dataclass
class Script:
    titel: str
    hook: str
    szenen: list[Scene]
    beschreibung: str = ""
    hashtags: list[str] = field(default_factory=list)
    quellen: list[Source] = field(default_factory=list)
    hook_overlay: str = ""
    hook_pexels_suchbegriffe: list[str] = field(default_factory=list)
    schluss_typ: str = "loop"

    @property
    def narration(self) -> str:
        """Der komplette Sprechertext: Hook + alle Szenen."""
        return " ".join(part for _, part in self.parts())

    def parts(self) -> list[tuple[int, str]]:
        """(Szenen-Index, Text); Index -1 ist der Hook."""
        return [(-1, self.hook.strip())] + [(i, s.text.strip()) for i, s in enumerate(self.szenen)]

    def word_count(self) -> int:
        return count_words(self.narration)

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Script":
        """Liest LLM-Ausgabe und eigene Skriptdateien (tolerant bei optionalen Feldern)."""
        if not isinstance(data, dict):
            raise ScriptError("Skript muss ein JSON-Objekt sein.")
        hook = str(data.get("hook") or "").strip()
        raw_scenes = data.get("szenen") or data.get("scenes") or []
        if not hook or not isinstance(raw_scenes, list) or not raw_scenes:
            raise ScriptError("Skript braucht mindestens „hook“ und eine nicht-leere Liste „szenen“.")
        scenes = []
        for i, item in enumerate(raw_scenes, 1):
            if isinstance(item, str):
                scenes.append(Scene(text=item.strip()))
            elif isinstance(item, dict) and str(item.get("text", "")).strip():
                terms = item.get("pexels_suchbegriffe") or item.get("suchbegriffe") or item.get("pexels") or []
                if isinstance(terms, str):
                    terms = [t.strip() for t in terms.split(",")]
                scenes.append(Scene(text=str(item["text"]).strip(), pexels_suchbegriffe=[t for t in terms if t]))
            else:
                raise ScriptError(f"Szene {i} hat keinen Text.")
        sources = []
        for item in data.get("quellen") or []:
            if isinstance(item, str):
                sources.append(Source(fakt="", quelle="", url=item.strip()))
            elif isinstance(item, dict):
                sources.append(Source(fakt=str(item.get("fakt", "")).strip(),
                                      quelle=str(item.get("quelle", "")).strip(),
                                      url=str(item.get("url", "")).strip()))
        hook_terms = data.get("hook_pexels_suchbegriffe") or []
        if isinstance(hook_terms, str):
            hook_terms = [t.strip() for t in hook_terms.split(",")]
        titel = str(data.get("titel") or "").strip() or " ".join(hook.split()[:6])
        schluss = str(data.get("schluss_typ") or "loop").strip().lower()
        return cls(
            titel=titel,
            hook=hook,
            szenen=scenes,
            beschreibung=str(data.get("beschreibung") or "").strip(),
            hashtags=normalize_hashtags(data.get("hashtags") or []),
            quellen=sources,
            hook_overlay=str(data.get("hook_overlay") or "").strip(),
            hook_pexels_suchbegriffe=[t for t in hook_terms if t],
            schluss_typ=schluss if schluss in ("loop", "teil2") else "loop",
        )


def normalize_hashtags(tags) -> list[str]:
    if isinstance(tags, str):
        tags = tags.split()
    out: list[str] = []
    for tag in tags:
        tag = "#" + re.sub(r"[\s#]+", "", str(tag)).lower()
        if len(tag) > 1 and tag not in out:
            out.append(tag)
    return out


def ensure_hashtags(script: Script, niche: Niche) -> None:
    """3–5 Hashtags garantieren (auffüllen aus dem Nischen-Pool bzw. kürzen)."""
    tags = list(script.hashtags)
    for tag in normalize_hashtags(niche.hashtags):
        if len(tags) >= 3:
            break
        if tag not in tags:
            tags.append(tag)
    script.hashtags = tags[:5]


def load_script_file(path: Path) -> Script:
    if not path.exists():
        raise ScriptError(f"Skriptdatei nicht gefunden: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ScriptError(f"{path.name} ist kein gültiges JSON (Zeile {exc.lineno}): {exc.msg}") from exc
    return Script.from_dict(data)


# --------------------------------------------------------------------------------------
# Regelprüfung
# --------------------------------------------------------------------------------------
def validate(script: Script, cfg: Config, *, check_length: bool = True) -> list[str]:
    """Liste verletzter Regeln (leer = alles ok). Formuliert als Korrekturanweisung."""
    problems: list[str] = []
    lo, hi = cfg.script.min_words, cfg.script.max_words
    n = script.word_count()
    if check_length and not lo <= n <= hi:
        problems.append(f"Der gesprochene Text (Hook + Szenen) hat {n} Wörter, erlaubt sind {lo}–{hi}.")
    hook_words = count_words(script.hook)
    if hook_words > HOOK_MAX_WORDS + 2:
        problems.append(f"Der Hook hat {hook_words} Wörter – höchstens {HOOK_MAX_WORDS}, "
                        "damit er in den ersten 2 Sekunden sitzt.")
    if _GREETING.match(script.hook):
        problems.append("Der Hook beginnt mit einer Begrüßung oder Floskel – steig direkt mit der Behauptung "
                        "oder Frage ein.")
    if len(script.szenen) < 6:
        problems.append(f"Nur {len(script.szenen)} Szenen – nötig sind 9–16, damit alle 2–4 Sekunden ein "
                        "neues Bild kommt.")
    for i, scene in enumerate(script.szenen, 1):
        words = count_words(scene.text)
        if words > SCENE_MAX_WORDS:
            problems.append(f"Szene {i} hat {words} Wörter – in 1–2 kurze Sätze aufteilen.")
        if not scene.pexels_suchbegriffe:
            problems.append(f"Szene {i} hat keine Pexels-Suchbegriffe.")
    if not 3 <= len(script.hashtags) <= 5:
        problems.append(f"Es sind {len(script.hashtags)} Hashtags – nötig sind 3–5.")
    bad_tags = [t for t in script.hashtags if not _HASHTAG.fullmatch(t)]
    if bad_tags:
        problems.append(f"Ungültige Hashtags: {', '.join(bad_tags)}")
    if len(script.quellen) < 2:
        problems.append("Zu wenige Quellen – zu jedem Fakt und jeder Zahl gehört eine Quelle mit URL.")
    bad_urls = [q.url for q in script.quellen if not q.url.startswith(("http://", "https://"))]
    if bad_urls:
        problems.append(f"Quellen ohne gültige URL: {', '.join(bad_urls) or '(leer)'}")
    return problems


def _norm_url(url: str) -> str:
    url = re.sub(r"^https?://(www\.)?", "", url.strip().lower())
    return url.split("#")[0].rstrip("/")


def check_sources(script: Script, research_urls: list[str] | None = None) -> list[dict]:
    """Prüft jede Quellen-URL auf Erreichbarkeit und ob sie in der Websuche vorkam."""
    found = {_norm_url(u) for u in research_urls or []}
    results = []
    for url in dict.fromkeys(src.url for src in script.quellen):
        entry = {"url": url, "erreichbar": None, "status": None,
                 "in_recherche": (_norm_url(url) in found) if research_urls is not None else None}
        try:
            resp = http_request("HEAD", url, retries=2, timeout=12, allow_redirects=True)
            if resp.status_code >= 400:  # manche Seiten lehnen HEAD ab
                resp = http_request("GET", url, retries=2, timeout=15, allow_redirects=True, stream=True)
                resp.close()
            entry["status"] = resp.status_code
            entry["erreichbar"] = resp.status_code < 400
        except HttpError as exc:
            entry["status"] = str(exc)
            entry["erreichbar"] = False
        log.debug("Quelle %s: %s", url, entry["status"])
        results.append(entry)
    return results


# --------------------------------------------------------------------------------------
# Prompts
# --------------------------------------------------------------------------------------
SCRIPT_SCHEMA = {
    "type": "object",
    "properties": {
        "titel": {"type": "string"},
        "hook": {"type": "string"},
        "hook_overlay": {"type": "string"},
        "hook_pexels_suchbegriffe": {"type": "array", "items": {"type": "string"}},
        "szenen": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "pexels_suchbegriffe": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["text", "pexels_suchbegriffe"],
                "additionalProperties": False,
            },
        },
        "schluss_typ": {"type": "string", "enum": ["loop", "teil2"]},
        "beschreibung": {"type": "string"},
        "hashtags": {"type": "array", "items": {"type": "string"}},
        "quellen": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "fakt": {"type": "string"},
                    "quelle": {"type": "string"},
                    "url": {"type": "string"},
                },
                "required": ["fakt", "quelle", "url"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["titel", "hook", "hook_overlay", "hook_pexels_suchbegriffe", "szenen", "schluss_typ",
                 "beschreibung", "hashtags", "quellen"],
    "additionalProperties": False,
}

TOPICS_SCHEMA = {
    "type": "object",
    "properties": {
        "ideen": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"thema": {"type": "string"}, "winkel": {"type": "string"}},
                "required": ["thema", "winkel"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["ideen"],
    "additionalProperties": False,
}

SCRIPT_SYSTEM = """Du bist Head-Writer für TikTok-Wissensvideos (65–75 Sekunden, Sprecherstimme, große Untertitel).
Deine Skripte halten Zuschauer bis zur letzten Sekunde, weil jede Zeile eine Frage öffnet, die erst später beantwortet wird – und weil jeder Fakt stimmt.

Pflichtregeln:
1. Länge: {min_words}–{max_words} gesprochene Wörter insgesamt (Hook + alle Szenen). Zähle nach, bevor du antwortest.
2. Hook = die ersten 2 Sekunden, höchstens {hook_max} Wörter: überraschende Behauptung, direkte Frage oder offene Schleife. Verboten: „Hallo“, „Hey“, „Heute“, „In diesem Video“, jede Begrüßung oder Selbstvorstellung.
3. Danach 3–5 inhaltliche Punkte. Jeder Punkt endet mit einem Mini-Cliffhanger, der in den nächsten Punkt zieht.
4. Der stärkste, verblüffendste Fakt kommt zuletzt.
5. Schluss: entweder ein Loop – der letzte Satz führt nahtlos zurück in den ersten Satz, sodass das Video beim Wiederholen weiterläuft – oder eine klare Ankündigung von Teil 2. Kein „Folge mir“, keine Bitte um Likes oder Kommentare.
6. Gesprochene Sprache: kurze Sätze (meist unter 12 Wörtern), aktive Verben, du-Ansprache, keine Schachtelsätze, keine Abkürzungen, keine Klammern. Ziffern sind erlaubt; schreibe „Prozent“, „Euro“, „Grad“ statt Symbolen.
7. Nur überprüfbare Fakten: Jede Zahl und jede konkrete Behauptung muss durch eine Quelle gedeckt sein. Nichts erfinden, nicht aufrunden, nicht übertreiben. Umstrittenes als umstritten kennzeichnen.
8. Keine Gesundheits-, Therapie-, Rechts- oder Finanzratschläge, keine Anlage- oder Produktempfehlungen. Allgemeinbildung ja, persönliche Handlungsanweisungen mit Risiko nein.
9. Keine Tragödien als Clickbait, keine politische Polarisierung, keine Bloßstellung realer Privatpersonen.
10. Eigenständig formuliert – nichts von anderen Videos, Artikeln oder Reddit-Posts übernehmen.

Struktur:
- szenen: der Text NACH dem Hook, aufgeteilt in 9–16 Szenen mit je 1–2 Sätzen (etwa 8–20 Wörter). Szenen sind die Schnitteinheiten für das Bildmaterial.
- pexels_suchbegriffe: pro Szene 2–3 englische Suchbegriffe für Stock-Videos, die zeigen, was gerade gesagt wird. Konkrete, filmbare Motive (z. B. „astronaut floating in space“, „old library books“) – keine abstrakten Wörter, keine Namen realer Personen, keine Marken, keine Schrift.
- Sprache des Skripts: {language}."""

_LANGUAGE = {"de": "Deutsch (de-DE)", "en": "Englisch (en-US) – auch Titel, Beschreibung und Hashtags auf Englisch"}


def _bullets(items: list[str]) -> str:
    return "\n".join(f"- {i}" for i in items) if items else "- (keine)"


def _system(cfg: Config, lang: str) -> str:
    return SCRIPT_SYSTEM.format(min_words=cfg.script.min_words, max_words=cfg.script.max_words,
                                hook_max=HOOK_MAX_WORDS, language=_LANGUAGE[lang])


def _research_block(research: Research | None) -> str:
    if research is None:
        return ("Keine Websuche-Recherche verfügbar. Nutze nur gut belegte, allgemein anerkannte Fakten und gib "
                "für jeden die seriöseste Quelle mit einer URL an, die du sicher kennst. Bist du dir bei einer "
                "Unterseite nicht sicher, nenne die Startseite der Institution – erfinde keine URLs.")
    return ("Recherche-Notizen – verwende nur Fakten, die hier mit Quelle stehen, und übernimm die URLs exakt:\n"
            f"<recherche>\n{research.text}\n</recherche>")


# --------------------------------------------------------------------------------------
# Claude-Schritte
# --------------------------------------------------------------------------------------
def propose_topics(llm: LLM, cfg: Config, niche: Niche, history: History, count: int,
                   lang: str = "de") -> list[dict]:
    """Schlägt count neue, unterschiedliche Themen vor (ohne Wiederholungen aus history.json)."""
    previous = history.topics(niche.key)
    prompt = f"""Nische: {niche.name}
Themenfelder: {", ".join(niche.themenfelder) or "frei"}
Tonalität: {niche.tonalitaet}
Nischen-Regeln:
{_bullets(niche.regeln)}

Schlage {count + 3} Themen für 70-Sekunden-Wissensvideos vor. Jedes Thema muss
- auf überprüfbaren Fakten beruhen (keine Mythen, keine Spekulation als Fakt),
- einen echten Überraschungsmoment haben, den man in einem Satz anteasern kann,
- sich klar von den anderen Vorschlägen und von diesen bereits produzierten Themen unterscheiden:
{_bullets(previous)}

Streue über verschiedene Themenfelder. Keine Tragödien als Clickbait, keine Gesundheits- oder Finanzratschläge,
keine politische Polarisierung. Sprache der Themen: {_LANGUAGE[lang]}.
Felder: thema (prägnanter Arbeitstitel), winkel (der überraschende Kern in einem Satz)."""
    data = llm.structured("Du entwickelst Themen für TikTok-Wissensvideos mit hoher Wiedersehens- und Teilen-Rate.",
                          prompt, TOPICS_SCHEMA)
    ideas = []
    for idea in data.get("ideen", []):
        dup = history.find_duplicate(idea["thema"])
        if dup or any(similar(idea["thema"], i["thema"]) for i in ideas):
            log.info("Thema verworfen (ähnlich zu „%s“): %s", dup or "anderem Vorschlag", idea["thema"])
            continue
        ideas.append(idea)
    if not ideas:
        raise ScriptError(f"Claude hat keine neuen Themen für „{niche.name}“ gefunden – history.json prüfen.")
    return ideas[:count]


def research_topic(llm: LLM, cfg: Config, topic: str, angle: str, niche: Niche) -> Research:
    prompt = f"""Recherchiere per Websuche für ein 70-Sekunden-Wissensvideo.
Thema: {topic}
Winkel: {angle or "frei"}
Nische: {niche.name}

Finde 6–9 überraschende, belegbare Fakten, darunter einen besonders starken „Wow“-Fakt.
Bevorzuge Primär- und Fachquellen: Universitäten, Fachzeitschriften, Behörden, Forschungsinstitute, NASA/ESA,
Museen, Enzyklopädien, Qualitätsmedien.
Für jeden Fakt:
1. der Fakt in einem Satz (deutsch), mit exakten Zahlen aus der Quelle
2. Quelle: Name der Institution oder Publikation
3. URL der Seite, auf der der Fakt steht – exakt so, wie sie im Suchergebnis steht
4. Hinweis, falls der Fakt umstritten, veraltet oder vereinfacht ist
Nenne nur Fakten, die du in einem Suchergebnis gesehen hast. Antworte als nummerierte Liste ohne Einleitung."""
    research = llm.research(
        "Du bist Faktenrechercheur für ein Wissensformat. Du arbeitest gründlich und nennst nur Fakten, "
        "die du in einer gefundenen Quelle gesehen hast.",
        prompt, max_searches=cfg.script.research_max_searches)
    log.info("Recherche: %d Quellen-URLs gefunden", len(research.urls))
    return research


def write_script(llm: LLM, cfg: Config, *, topic: str, angle: str, niche: Niche, research: Research | None,
                 history: History, lang: str = "de", trend_note: str = "") -> Script:
    """Schreibt das Skript und lässt Regelverstöße bis zu max_attempts-mal korrigieren."""
    system = _system(cfg, lang)
    prompt = f"""Thema: {topic}
Winkel/Aufhänger: {angle or "frei"}
{trend_note}
Nische: {niche.name}
Tonalität: {niche.tonalitaet}
Nischen-Regeln:
{_bullets(niche.regeln)}

{_research_block(research)}

Bereits veröffentlichte Themen dieser Nische (nicht wiederholen, keine gleichen Fakten):
{_bullets(history.topics(niche.key, limit=30))}

Hashtag-Pool: {" ".join(niche.hashtags)} – wähle 3–5 passende; höchstens einer darf themenspezifisch neu sein.

Felder:
- titel: max. 6 Wörter, macht neugierig (steht groß auf dem Cover)
- hook: der gesprochene Hook (max. {HOOK_MAX_WORDS} Wörter)
- hook_overlay: Texteinblendung für Sekunde 0–2, max. 6 Wörter, darf den Hook zuspitzen
- hook_pexels_suchbegriffe: 2–3 englische Suchbegriffe für das stärkste Eröffnungsbild
- szenen: der Rest des Sprechertexts als Liste {{text, pexels_suchbegriffe}} (ohne den Hook)
- schluss_typ: "loop" oder "teil2"
- beschreibung: TikTok-Beschreibung, 1–2 Sätze mit Suchbegriffen, max. 150 Zeichen, ohne Hashtags
- hashtags: 3–5, mit #, kleingeschrieben, ohne Leerzeichen
- quellen: für jeden Fakt und jede Zahl ein Eintrag {{fakt, quelle, url}}"""
    script = Script.from_dict(llm.structured(system, prompt, SCRIPT_SCHEMA))
    for attempt in range(1, cfg.script.max_attempts + 1):
        problems = validate(script, cfg)
        if not problems:
            break
        log.info("Skript verletzt %d Regel(n), Korrektur %d/%d: %s", len(problems), attempt,
                 cfg.script.max_attempts, " | ".join(problems))
        script = _revise(llm, system, script, problems, research)
    else:
        problems = validate(script, cfg)
        if problems:
            log.warning("Skript nach %d Korrekturen nicht regelkonform: %s", cfg.script.max_attempts,
                        " | ".join(problems))
    ensure_hashtags(script, niche)
    return script


def _revise(llm: LLM, system: str, script: Script, instructions: list[str], research: Research | None) -> Script:
    prompt = f"""Dein letztes Skript (JSON):
{json.dumps(script.to_dict(), ensure_ascii=False, indent=1)}

Überarbeite es:
{_bullets(instructions)}

Behalte gelungene Teile bei, besonders Hook und stärksten Fakt. Alle Pflichtregeln gelten weiter.
Gib das vollständige Skript erneut aus.

{_research_block(research)}"""
    return Script.from_dict(llm.structured(system, prompt, SCRIPT_SCHEMA))


def revise_for_duration(llm: LLM, cfg: Config, script: Script, research: Research | None, *,
                        spoken_seconds: float, lang: str = "de") -> Script:
    """Verlängert/kürzt das Skript, wenn die Vertonung außerhalb 61–90 s liegt."""
    words = script.word_count()
    wps = words / max(spoken_seconds, 1.0)
    target_words = math.ceil(wps * cfg.duration.target)
    if spoken_seconds < cfg.duration.min_hard:
        how = (f"Verlängere den gesprochenen Text auf etwa {target_words} Wörter (jetzt {words}). "
               "Füge einen weiteren belegten Fakt oder ein anschauliches Detail hinzu – keine Füllwörter, "
               "kein Wiederholen.")
    else:
        how = (f"Kürze den gesprochenen Text auf etwa {target_words} Wörter (jetzt {words}). "
               "Streiche Nebensätze und den schwächsten Punkt – Hook, stärksten Fakt und Schluss behalten.")
    instructions = [
        f"Die Vertonung dauert {spoken_seconds:.1f} Sekunden; erlaubt sind {cfg.duration.min_hard}–"
        f"{cfg.duration.max_hard} Sekunden, Ziel sind {cfg.duration.target} Sekunden. Die Stimme spricht "
        f"etwa {wps:.2f} Wörter pro Sekunde. Die Wortgrenze aus Regel 1 gilt hier nicht – die Dauer hat Vorrang.",
        how,
    ]
    log.info("Skript wird %s (%d → ~%d Wörter)",
             "verlängert" if spoken_seconds < cfg.duration.min_hard else "gekürzt", words, target_words)
    return _revise(llm, _system(cfg, lang), script, instructions, research)
