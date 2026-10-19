#!/usr/bin/env python3
"""Bündelt Roblox-Nachbildung, Spielskripte und Testablauf zu einer Luau-Datei und führt sie aus.

Aufruf:  python3 tools/run_client_test.py /pfad/zu/luau
Jedes Modul wird in eine Funktion mit dem Parameter `script` verpackt; Roblox-Globale
(game, workspace, Instance, Vector3, ...) kommen aus tests/roblox_mock.luau.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULES = {
    "shared/Config": "src/shared/Config.luau",
    "shared/Skins": "src/shared/Skins.luau",
    "shared/Rules": "src/shared/Rules.luau",
    "client/Fx": "src/client/Fx.luau",
    "client/Models": "src/client/Models.luau",
    "client/Board": "src/client/Board.luau",
    "client/Ui": "src/client/Ui.luau",
    "client/init": "src/client/init.client.luau",
    "server/Progress": "src/server/Progress.server.luau",
}


def main() -> int:
    luau = sys.argv[1] if len(sys.argv) > 1 else "luau"
    parts = [(ROOT / "tests/roblox_mock.luau").read_text(encoding="utf-8"), "local __src = {}"]
    for name, rel in MODULES.items():
        src = (ROOT / rel).read_text(encoding="utf-8")
        parts.append(f'__src["{name}"] = function(script)\n{src}\nend')
    parts.append((ROOT / "tests/client_harness.luau").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as tmp:
        bundle = pathlib.Path(tmp) / "client_bundle.luau"
        bundle.write_text("\n".join(parts), encoding="utf-8")
        return subprocess.run([luau, str(bundle)]).returncode


if __name__ == "__main__":
    sys.exit(main())
