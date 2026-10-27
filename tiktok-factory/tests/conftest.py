import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from factory.config import Config  # noqa: E402
from factory.script import Scene, Script, Source  # noqa: E402


@pytest.fixture(scope="session")
def cfg() -> Config:
    return Config(ROOT)


@pytest.fixture
def script() -> Script:
    return Script(
        titel="Warum Träume verschwinden",
        hook="Du vergisst 95 Prozent deiner Träume.",
        hook_overlay="Dein Gehirn löscht Träume",
        hook_pexels_suchbegriffe=["sleeping woman", "night bedroom"],
        szenen=[
            Scene("Und zwar fast sofort nach dem Aufwachen.", ["alarm clock morning"]),
            Scene("Schuld ist ein Botenstoff namens Noradrenalin.", ["brain neurons", "laboratory"]),
            Scene("Im REM-Schlaf ist er fast komplett abgeschaltet.", ["sleep lab"]),
            Scene("Aber das ist noch nicht das Seltsamste.", ["dark corridor"]),
        ],
        beschreibung="Warum wir Träume vergessen – die Neurowissenschaft dahinter.",
        hashtags=["#psychologie", "#träume", "#wusstestdu"],
        quellen=[Source("Noradrenalin im REM-Schlaf", "Beispiel-Uni", "https://example.org/a"),
                 Source("Traumvergessen", "Beispiel-Journal", "https://example.org/b")],
    )
