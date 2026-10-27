"""Claude-Anbindung offline prüfen: lokaler Stub-Server statt api.anthropic.com."""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from factory.history import History
from factory.llm import FALLBACK_BETA, LLM
from factory.script import write_script
from factory.tts.azure import AzureVoice


class Stub(BaseHTTPRequestHandler):
    responses: list[dict] = []
    requests: list[tuple[dict, dict]] = []

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Stub.requests.append(({k.lower(): v for k, v in self.headers.items()}, body))
        data = json.dumps(Stub.responses.pop(0)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def message(content, stop_reason="end_turn"):
    return {"id": "msg_test", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
            "content": content, "stop_reason": stop_reason, "stop_sequence": None,
            "usage": {"input_tokens": 10, "output_tokens": 20}}


@pytest.fixture
def stub(monkeypatch):
    server = HTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("FACTORY_ANTHROPIC_BASE_URL", f"http://127.0.0.1:{server.server_port}")
    monkeypatch.setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:9")   # fremde Belegung muss ignoriert werden
    monkeypatch.delenv("FACTORY_ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.setenv("ANTHROPIC_MODEL", "claude-sonnet-5-5")
    Stub.responses, Stub.requests = [], []
    yield Stub
    server.shutdown()


def test_structured_request_shape(cfg, stub):
    stub.responses.append(message([{"type": "text", "text": '{"ideen": []}'}]))
    data = LLM(cfg).structured("System", "Prompt", {"type": "object"})
    headers, body = stub.requests[0]
    assert data == {"ideen": []}
    assert body["model"] == "claude-sonnet-5-5"
    assert body["fallbacks"] == "default" and FALLBACK_BETA in headers["anthropic-beta"]
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert "temperature" not in body and "thinking" not in body


def test_research_collects_urls_across_pause_turn(cfg, stub):
    search = [{"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "oktopus"}},
              {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
               "content": [{"type": "web_search_result", "url": "https://example.org/a", "title": "A",
                            "encrypted_content": "x", "page_age": None}]}]
    stub.responses += [message(search, "pause_turn"),
                       message([{"type": "text", "text": "1. Fakt – https://example.org/b",
                                 "citations": [{"type": "web_search_result_location", "url": "https://example.org/b",
                                                "title": "B", "encrypted_index": "y", "cited_text": "z"}]}])]
    research = LLM(cfg).research("System", "Prompt", max_searches=3)
    assert research.text.startswith("1. Fakt")
    assert research.urls == ["https://example.org/a", "https://example.org/b"]
    _, second = stub.requests[1]
    assert second["messages"][-1]["role"] == "assistant"         # pause_turn wird fortgesetzt
    assert second["tools"][0]["type"] == "web_search_20260209"


def test_refusal_is_reported(cfg, stub):
    resp = message([], "refusal")
    resp["stop_details"] = {"type": "refusal", "category": "cyber", "explanation": "x"}
    stub.responses.append(resp)
    with pytest.raises(Exception, match="abgelehnt"):
        LLM(cfg).structured("S", "P", {"type": "object"})


def test_write_script_repairs_rule_violations(cfg, stub, script, tmp_path):
    script.szenen = script.szenen * 3
    i = 0
    while script.word_count() < cfg.script.min_words + 5:   # Füllsätze gleichmäßig verteilen
        script.szenen[i % len(script.szenen)].text += " Wirklich wahr."
        i += 1
    good = script.to_dict()
    bad = good | {"hashtags": ["#nur", "#zwei"]}
    stub.responses += [message([{"type": "text", "text": json.dumps(bad)}]),
                       message([{"type": "text", "text": json.dumps(good)}])]
    result = write_script(LLM(cfg), cfg, topic="Träume", angle="", niche=cfg.niche("psychologie"),
                          research=None, history=History(tmp_path / "h.json"))
    assert len(stub.requests) == 2                                # einmal korrigiert
    assert "Hashtags" in stub.requests[1][1]["messages"][0]["content"]
    assert 3 <= len(result.hashtags) <= 5


def test_azure_ssml_is_escaped():
    voice = AzureVoice("de-DE-KatjaNeural", key="k", region="westeurope", base_rate="+5%")
    ssml = voice.ssml("Salz & Pfeffer <scharf>", rate_pct=-3)
    assert 'xml:lang="de-DE"' in ssml and 'rate="+2%"' in ssml
    assert "Salz &amp; Pfeffer &lt;scharf&gt;" in ssml
