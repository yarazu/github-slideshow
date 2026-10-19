#!/usr/bin/env python3
"""Baut KrawallKoenigreich.rbxlx aus src/ nach denselben Regeln wie Rojo (default.project.json).

Nur nötig, wenn Rojo nicht installiert ist; mit Rojo geht es so:  rojo build -o KrawallKoenigreich.rbxlx
Konventionen: Ordner -> Folder, init.client.luau macht den Ordner zum LocalScript,
*.server.luau -> Script, *.client.luau -> LocalScript, *.luau -> ModuleScript.
"""
import pathlib
import sys
import uuid
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent


def ref() -> str:
    return "RBX" + uuid.uuid4().hex.upper()


def item(cls: str, name: str, props: str = "", children: str = "", source: str | None = None) -> str:
    body = f'<string name="Name">{escape(name)}</string>{props}'
    if source is not None:
        if "]]>" in source:
            raise SystemExit(f"{name}: Quelltext enthält ']]>'")
        body += f'<ProtectedString name="Source"><![CDATA[{source}]]></ProtectedString>'
    return f'<Item class="{cls}" referent="{ref()}"><Properties>{body}</Properties>{children}</Item>'


def script_class(path: pathlib.Path) -> tuple[str, str]:
    name = path.name
    if name.endswith(".server.luau"):
        return "Script", name[: -len(".server.luau")]
    if name.endswith(".client.luau"):
        return "LocalScript", name[: -len(".client.luau")]
    return "ModuleScript", name[: -len(".luau")]


def build_dir(path: pathlib.Path, name: str) -> str:
    init_cls, init_src = "Folder", None
    for init_name, cls in (("init.client.luau", "LocalScript"), ("init.server.luau", "Script"), ("init.luau", "ModuleScript")):
        f = path / init_name
        if f.exists():
            init_cls, init_src = cls, f.read_text(encoding="utf-8")
    children = []
    for child in sorted(path.iterdir()):
        if child.name.startswith("init."):
            continue
        if child.is_dir():
            children.append(build_dir(child, child.name))
        elif child.suffix == ".luau":
            cls, cname = script_class(child)
            children.append(item(cls, cname, source=child.read_text(encoding="utf-8")))
    return item(init_cls, name, children="".join(children), source=init_src)


def main() -> None:
    out = ROOT / (sys.argv[1] if len(sys.argv) > 1 else "KrawallKoenigreich.rbxlx")
    services = [
        item("Workspace", "Workspace"),
        item("Lighting", "Lighting", props='<token name="Technology">3</token>'),
        item("Players", "Players", props='<bool name="CharacterAutoLoads">false</bool>'),
        item("ReplicatedStorage", "ReplicatedStorage", children=build_dir(ROOT / "src/shared", "Krawall")),
        item("ServerScriptService", "ServerScriptService", children=build_dir(ROOT / "src/server", "KrawallServer")),
        item(
            "StarterPlayer",
            "StarterPlayer",
            children=item("StarterPlayerScripts", "StarterPlayerScripts", children=build_dir(ROOT / "src/client", "KrawallClient")),
        ),
    ]
    xml = (
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">'
        '<External>null</External><External>nil</External>' + "".join(services) + "</roblox>"
    )
    out.write_text(xml, encoding="utf-8")
    print(f"geschrieben: {out}")


if __name__ == "__main__":
    main()
