"""Claude-Anbindung: strukturierte JSON-Antworten und Websuche-Recherche."""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field

import anthropic

from .config import Config
from .errors import ConfigError, ScriptError

log = logging.getLogger(__name__)

# Server-seitiger Fallback bei Ablehnungen durch Sicherheitsfilter. Auf Modellen ohne
# Fallback-Unterstützung läuft die Anfrage unverändert auf dem gewählten Modell.
FALLBACK_BETA = "server-side-fallback-2026-07-01"
WEB_SEARCH_TOOL = "web_search_20260209"
DEFAULT_MODEL = "claude-sonnet-5-5"


@dataclass
class Research:
    text: str
    urls: list[str] = field(default_factory=list)  # URLs, die die Websuche wirklich geliefert hat


def api_key(cfg: Config) -> str | None:
    """FACTORY_ANTHROPIC_API_KEY hat Vorrang – für Umgebungen, in denen ANTHROPIC_API_KEY schon belegt ist."""
    return cfg.env("FACTORY_ANTHROPIC_API_KEY") or cfg.env("ANTHROPIC_API_KEY")


class LLM:
    def __init__(self, cfg: Config):
        key = api_key(cfg)
        if not key:
            raise ConfigError("ANTHROPIC_API_KEY fehlt in .env (Vorlage: .env.example). "
                              "Ohne Key: eigenes Skript mit --script-file verwenden.")
        # Bewusst nicht ANTHROPIC_BASE_URL: die Variable kann von anderen Tools (z. B. einem Agenten-Proxy)
        # belegt sein – der Key soll nur an die echte API gehen.
        base_url = cfg.env("FACTORY_ANTHROPIC_BASE_URL", "https://api.anthropic.com")
        self.client = anthropic.Anthropic(api_key=key, base_url=base_url, max_retries=4)
        self.model = cfg.env("ANTHROPIC_MODEL", DEFAULT_MODEL)
        self.effort = cfg.env("ANTHROPIC_EFFORT", "medium")

    # ------------------------------------------------------------------------------
    def _create(self, **kwargs):
        try:
            return self.client.beta.messages.create(
                model=self.model,
                betas=[FALLBACK_BETA],
                fallbacks="default",
                **kwargs,
            )
        except anthropic.AuthenticationError as exc:
            raise ConfigError("Anthropic-API-Key ungültig – ANTHROPIC_API_KEY in .env prüfen.") from exc
        except anthropic.PermissionDeniedError as exc:
            raise ConfigError(f"Anthropic-API verweigert den Zugriff: {exc.message} "
                              "(Websuche in der Console erlaubt? Sonst SCRIPT_WEB_SEARCH=false)") from exc
        except anthropic.NotFoundError as exc:
            raise ConfigError(f"Modell „{self.model}“ nicht verfügbar – ANTHROPIC_MODEL in .env prüfen.") from exc
        except anthropic.RateLimitError as exc:
            raise ScriptError("Anthropic-Rate-Limit erreicht – bitte später erneut versuchen.") from exc
        except anthropic.BadRequestError as exc:
            raise ScriptError(f"Anthropic-API lehnt die Anfrage ab: {exc.message}") from exc
        except anthropic.APIStatusError as exc:
            raise ScriptError(f"Anthropic-API-Fehler {exc.status_code}: {exc.message}") from exc
        except anthropic.APIConnectionError as exc:
            raise ScriptError("Keine Verbindung zur Anthropic-API (Internet/Proxy prüfen).") from exc

    @staticmethod
    def _check_stop(resp) -> None:
        if resp.stop_reason == "refusal":
            details = getattr(resp, "stop_details", None)
            category = getattr(details, "category", None) if details else None
            raise ScriptError(f"Claude hat die Anfrage abgelehnt (Kategorie: {category or 'unbekannt'}). "
                              "Thema umformulieren.")
        if resp.stop_reason == "max_tokens":
            raise ScriptError("Claude-Antwort wurde abgeschnitten (max_tokens).")

    @staticmethod
    def _text(resp) -> str:
        return "".join(block.text for block in resp.content if block.type == "text")

    # ------------------------------------------------------------------------------
    def structured(self, system: str, prompt: str, schema: dict, *, effort: str | None = None,
                   max_tokens: int = 16000) -> dict:
        """Antwort garantiert im JSON-Schema (Structured Outputs)."""
        resp = self._create(
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": prompt}],
            output_config={
                "effort": effort or self.effort,
                "format": {"type": "json_schema", "schema": schema},
            },
        )
        self._check_stop(resp)
        log.debug("Claude-Antwort (%s Ausgabe-Tokens)", getattr(resp.usage, "output_tokens", "?"))
        try:
            return json.loads(self._text(resp))
        except json.JSONDecodeError as exc:
            raise ScriptError(f"Claude lieferte kein gültiges JSON: {exc}") from exc

    def research(self, system: str, prompt: str, *, max_searches: int = 6,
                 effort: str | None = None, max_tokens: int = 16000) -> Research:
        """Recherche mit Websuche. Liefert Notizen + alle tatsächlich gefundenen URLs."""
        tools = [{
            "type": WEB_SEARCH_TOOL,
            "name": "web_search",
            "max_uses": max_searches,
            "user_location": {"type": "approximate", "country": "DE", "timezone": "Europe/Berlin"},
        }]
        messages: list[dict] = [{"role": "user", "content": prompt}]
        texts: list[str] = []
        urls: list[str] = []
        for _ in range(5):  # pause_turn: Server-Tool-Schleife fortsetzen
            resp = self._create(max_tokens=max_tokens, system=system, tools=tools, messages=messages,
                                output_config={"effort": effort or self.effort})
            for block in resp.content:
                if block.type == "web_search_tool_result" and isinstance(block.content, list):
                    urls.extend(r.url for r in block.content if getattr(r, "url", None))
                elif block.type == "web_search_tool_result":
                    log.warning("Websuche meldet Fehler: %s", getattr(block.content, "error_code", block.content))
                elif block.type == "text":
                    texts.append(block.text)
                    for cite in getattr(block, "citations", None) or []:
                        if getattr(cite, "url", None):
                            urls.append(cite.url)
            if resp.stop_reason != "pause_turn":
                self._check_stop(resp)
                break
            messages.append({"role": "assistant", "content": resp.content})
        text = "".join(texts).strip()
        if not text:
            raise ScriptError("Die Websuche-Recherche lieferte keinen Text.")
        return Research(text=text, urls=list(dict.fromkeys(urls)))
