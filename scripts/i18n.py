#!/usr/bin/env python3
"""Traducciones de Hush.

El español es el idioma de origen: cada texto de la interfaz es su propia clave. Las traducciones viven en
`Resources/i18n/<idioma>.json` ({"texto en español": "traducción"}), fáciles de editar a mano o en una PR.

    scripts/i18n.py extract           # compila y apunta en .build/i18n/keys.json los textos que usa la app
    scripts/i18n.py check             # dice qué falta por traducir en cada idioma (falla si falta algo)
    scripts/i18n.py audit             # busca textos en español que se hayan quedado sin marcar para traducir
    scripts/i18n.py build <Resources> # escribe <idioma>.lproj/Localizable.strings dentro de la app

Para añadir un idioma: crea `Resources/i18n/<código>.json` con `{}`, ejecuta `check` y rellena lo que falte.
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
I18N = os.path.join(ROOT, "Resources", "i18n")
OUT = os.path.join(ROOT, ".build", "i18n")
KEYS = os.path.join(OUT, "keys.json")
PLACES = os.path.join(OUT, "places.json")  # archivo:línea de cada texto que el compilador ha marcado
SOURCE_LANGUAGE = "es"
# Textos del Info.plist (los muestra macOS, por ejemplo al pedir Touch ID). Se traducen con la misma tabla.
INFO_PLIST = {"NSFaceIDUsageDescription": "Hush usa Touch ID para abrir tu base de datos sin escribir la contraseña maestra."}
APP_SOURCES = ("/Sources/Boveda/", "/Sources/BovedaCore/", "/Sources/HushMenu/")


def languages():
    return sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(I18N, "*.json")))


def load(lang):
    with open(os.path.join(I18N, f"{lang}.json"), encoding="utf-8") as f:
        return json.load(f)


def save(lang, table):
    with open(os.path.join(I18N, f"{lang}.json"), "w", encoding="utf-8") as f:
        json.dump(dict(sorted(table.items())), f, ensure_ascii=False, indent=2)
        f.write("\n")


def extract():
    """El compilador apunta cada texto traducible (Text("…"), L("…"), String(localized:)…) con su formato."""
    # Compilación aparte: solo se recompila lo que cambia y su .stringsdata se reescribe; el resto sigue valiendo.
    data, scratch = os.path.join(OUT, "stringsdata"), os.path.join(OUT, "build")
    if not glob.glob(os.path.join(data, "*.stringsdata")):
        subprocess.run(["rm", "-rf", scratch], check=True)
    os.makedirs(data, exist_ok=True)
    for product in ("Boveda", "HushMenu"):
        subprocess.run(["swift", "build", "--scratch-path", scratch, "--product", product,
                        "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", data],
                       cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    keys, places = set(), []
    for path in glob.glob(os.path.join(data, "*.stringsdata")):
        with open(path, encoding="utf-8") as f:
            content = json.load(f)
        if not any(part in content["source"] for part in APP_SOURCES):
            continue
        for table in content["tables"].values():
            keys.update(entry["key"] for entry in table if entry["key"].strip())
            source = os.path.relpath(os.path.realpath(content["source"]), os.path.realpath(ROOT))
            places.extend(f"{source}:{e['location']['startingLine']}" for e in table)
    with open(KEYS, "w", encoding="utf-8") as f:
        json.dump(sorted(keys), f, ensure_ascii=False, indent=0)
    with open(PLACES, "w", encoding="utf-8") as f:
        json.dump(sorted(places), f, indent=0)
    print(f"{len(keys)} textos")
    return keys


def current_keys():
    if not os.path.exists(KEYS):
        return extract() | set(INFO_PLIST.values())
    with open(KEYS, encoding="utf-8") as f:
        return set(json.load(f)) | set(INFO_PLIST.values())


def placeholders(text):
    return sorted(re.findall(r"%(?:\d+\$)?(?:lld|ld|d|@|\.?\d*f)", text))


def check():
    keys = current_keys()
    ok = True
    for lang in languages():
        table = load(lang)
        missing = sorted(k for k in keys if not table.get(k))
        unused = sorted(k for k in table if k not in keys)
        broken = sorted(k for k, v in table.items() if v and placeholders(k) != placeholders(v))
        print(f"{lang}: {len(keys) - len(missing)}/{len(keys)} traducidos"
              + (f", {len(unused)} sin usar" if unused else "") + (f", {len(broken)} con formato distinto" if broken else ""))
        for k in missing:
            print(f"  falta: {k!r}")
        for k in broken:
            print(f"  formato: {k!r} → {table[k]!r}")
        ok = ok and not missing and not broken
    return ok


SPANISH = re.compile(r"^[a-záéíóúñ]+(?: [a-záéíóúñ]+)+$|[áéíóúñ¿¡«»]|\b(?:de|la|el|las|los|en|con|para|una?|y|o|no|se|tu|tus)\b|^[A-ZÁÉÍÓÚ][a-záéíóúñ]+[.…:]?$")
# Literales que no son interfaz: rutas, claves internas del archivo KDBX, cabeceras, listas de contraseñas comunes…
IGNORE_LINE = re.compile(r"appending(?:Path(?:Component)?)?\(|User-Agent|public static let|kindKey|favoriteTag|precondition|"
                         r"^\s*//|^\s*///|logger|print\(|\"contraseña\", \"contrasena\"|\"madrid\", \"españa\"|"
                         r"^\s*case\s+\w+\s*=\s*\"|keyboardShortcut\(|info\[|userInfo:|"
                         r"column\(\[|\"yes\", \"sí\"")  # nombres de columnas de los CSV que se importan
# Nombres propios y claves que no se traducen.
IGNORE_TEXT = {"Hush", "Chromium", "Vivaldi", "Comet", "Mozilla", "Waterfox", "Mastercard", "Email", "Authentication", "no-totp"}


def interpolations_as(body, replacement):
    """Cambia cada interpolación \\(…) (aunque lleve paréntesis dentro) por `replacement`."""
    out, i = [], 0
    while i < len(body):
        if body.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(body) and depth:
                depth += {"(": 1, ")": -1}.get(body[i], 0)
                i += 1
            out.append(replacement)
        else:
            out.append(body[i])
            i += 1
    return "".join(out)


def literals(line):
    """Literales de una línea (con interpolaciones anidadas), sin contar comentarios."""
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith("//", i):
            break
        if line[i] == '"' and not line.startswith('"""', i):
            start, i = i, i + 1
            while i < n:
                if line.startswith("\\(", i):
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if line[i] == "(":
                            depth += 1
                        elif line[i] == ")":
                            depth -= 1
                        elif line[i] == '"':
                            i += 1
                            while i < n and line[i] != '"':
                                i += 2 if line[i] == "\\" else 1
                        i += 1
                    continue
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    break
                i += 1
            out.append((start, i + 1))
        i += 1
    return out


def audit():
    """Textos en español que el compilador no ha recogido: seguramente falta envolverlos en L("…")."""
    current_keys()
    with open(PLACES, encoding="utf-8") as f:
        marked = {}
        for place in json.load(f):
            marked[place] = marked.get(place, 0) + 1
    found = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "Sources", "*", "*.swift"))):
        if path.endswith(("Wordlist.swift", "PublicSuffixData.swift")) or "/HushBridge/" in path:
            continue
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        relative = os.path.relpath(path, ROOT)
        for number, line in enumerate(lines, 1):
            if IGNORE_LINE.search(line):
                continue
            texts = []
            for a, b in literals(line):
                body = line[a + 1:b - 1]
                plain = interpolations_as(body, "").strip()
                if plain and plain not in IGNORE_TEXT and SPANISH.search(plain):
                    texts.append(body)
            # En cada línea, el compilador tiene que haber marcado al menos tantos textos como hay en español.
            if len(texts) > marked.get(f"{relative}:{number}", 0):
                found += 1
                print(f"{relative}:{number}: " + " | ".join(texts))
    print(f"{found} posibles textos sin marcar")
    return found == 0


def strings_literal(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def build(resources):
    """No necesita compilar: vuelca cada tabla tal cual (el español va vacío, porque la clave ya es el texto)."""
    for lang in [SOURCE_LANGUAGE] + languages():
        folder = os.path.join(resources, f"{lang}.lproj")
        os.makedirs(folder, exist_ok=True)
        table = {} if lang == SOURCE_LANGUAGE else load(lang)
        with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as f:
            for key in sorted(table):
                if key and table.get(key):
                    f.write(f"{strings_literal(key)} = {strings_literal(table[key])};\n")
        with open(os.path.join(folder, "InfoPlist.strings"), "w", encoding="utf-8") as f:
            for name, text in INFO_PLIST.items():
                f.write(f"{name} = {strings_literal(table.get(text) or text)};\n")
    print(" ".join([SOURCE_LANGUAGE] + languages()))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "extract":
        extract()
    elif command == "check":
        sys.exit(0 if check() else 1)
    elif command == "audit":
        sys.exit(0 if audit() else 1)
    elif command == "build" and len(sys.argv) > 2:
        build(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
