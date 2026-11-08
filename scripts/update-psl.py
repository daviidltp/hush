#!/usr/bin/env python3
"""Regenera Sources/BovedaCore/PublicSuffixData.swift a partir de la Public Suffix List.

Uso: python3 scripts/update-psl.py [ruta a public_suffix_list.dat]
Sin ruta la descarga de https://publicsuffix.org/list/public_suffix_list.dat (MPL 2.0).
"""
import sys
import urllib.request
from pathlib import Path

if len(sys.argv) > 1:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
else:
    text = urllib.request.urlopen("https://publicsuffix.org/list/public_suffix_list.dat").read().decode("utf-8")

rules = []
for line in text.splitlines():
    line = line.strip().split(" ")[0]
    if not line or line.startswith("//"):
        continue
    prefix = ""
    if line[0] in "!*":
        # «!» = excepción; «*.» = comodín. Se conserva el prefijo y se pasa el resto a punycode.
        prefix, line = ("!", line[1:]) if line[0] == "!" else ("*.", line[2:])
    try:
        ascii_rule = ".".join(label.encode("idna").decode("ascii") if label else label for label in line.split("."))
    except UnicodeError:
        continue
    rules.append(prefix + ascii_rule.lower())

out = Path(__file__).resolve().parent.parent / "Sources/BovedaCore/PublicSuffixData.swift"
body = "\n".join(sorted(set(rules)))
out.write_text(
    "// Generado por scripts/update-psl.py a partir de la Public Suffix List (https://publicsuffix.org, MPL 2.0).\n"
    "// No editar a mano.\n\n"
    "enum PublicSuffixData {\n"
    f'    static let rules = #"""\n{body}\n"""#\n'
    "}\n",
    encoding="utf-8",
)
print(f"{len(rules)} reglas -> {out}")
