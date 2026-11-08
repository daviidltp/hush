#!/usr/bin/env python3
"""Arma la extensión de Hush para Chrome/Brave/Edge/Arc (carpeta) y para Firefox/Zen (.xpi).

Uso: build.py <carpeta de salida> <nombre del host nativo> <versión>
"""
import base64
import json
import shutil
import sys
import zipfile
from pathlib import Path

here = Path(__file__).resolve().parent
out, host, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

base = {
    "manifest_version": 3,
    "name": "Hush",
    "description": "Rellena tus contraseñas de Hush en cualquier web.",
    "version": version,
    "icons": {s: f"icons/icon-{s}.png" for s in ("16", "32", "48", "128")},
    "permissions": ["nativeMessaging", "storage", "tabs"],
    "host_permissions": ["<all_urls>"],
    "action": {"default_title": "Hush", "default_popup": "popup.html",
               "default_icon": {s: f"icons/icon-{s}.png" for s in ("16", "32")}},
    "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "all_frames": True, "run_at": "document_idle"}],
    "commands": {"autofill": {"suggested_key": {"default": "Ctrl+Shift+L", "mac": "Command+Shift+L"},
                              "description": "Rellenar con la última cuenta usada en esta web"}},
}


def copy_sources(target: Path):
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(here / "src", target)
    background = (target / "background.js").read_text().replace("__HOST__", host)
    (target / "background.js").write_text(background)
    # El icono de la app va incrustado en content.js: sin archivos accesibles desde la web.
    icon = base64.b64encode((here / "src" / "icons" / "icon-48.png").read_bytes()).decode()
    content = (target / "content.js").read_text().replace("__ICON__", f"data:image/png;base64,{icon}")
    (target / "content.js").write_text(content)


# Chrome y familia: carpeta sin empaquetar. La clave fija el identificador de la extensión.
chromium = dict(base, key=(here / "chrome-key.txt").read_text().strip(), background={"service_worker": "background.js"})
copy_sources(out / "chromium")
(out / "chromium" / "manifest.json").write_text(json.dumps(chromium, ensure_ascii=False, indent=2))

# Firefox y Zen: .xpi con su identificador.
firefox = dict(base, background={"scripts": ["background.js"]},
               browser_specific_settings={"gecko": {"id": "hush@davidlopez.app", "strict_min_version": "128.0"}})
staging = out / ".firefox"
copy_sources(staging)
(staging / "manifest.json").write_text(json.dumps(firefox, ensure_ascii=False, indent=2))
with zipfile.ZipFile(out / "Hush.xpi", "w", zipfile.ZIP_DEFLATED) as xpi:
    for file in sorted(staging.rglob("*")):
        if file.is_file():
            xpi.write(file, file.relative_to(staging).as_posix())
shutil.rmtree(staging)
