#!/usr/bin/env python3
"""Builds the Lex keyboard's emoji list: iOS/Keyboard/Data/emoji.tsv.

    python3 scripts/make-emoji.py [folder for the downloads]

Sources (downloaded into the folder if they aren't there yet), both under the Unicode
license (https://www.unicode.org/license.txt):
  - emoji-test.txt: every emoji in keyboard order, with its group and skin tones
  - CLDR annotations: English and Hebrew names and search words

Emoji newer than MAX_VERSION are left out until iPhones can draw them.
"""
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

MAX_VERSION = 17.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "iOS", "Keyboard", "Data", "emoji.tsv")
SOURCES = {
    "emoji-test.txt": "https://unicode.org/Public/emoji/latest/emoji-test.txt",
    "en.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/en.xml",
    "he.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/he.xml",
    "en-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/en.xml",
    "he-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/he.xml",
}
TONES = {"1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"}


def fetch(folder):
    os.makedirs(folder, exist_ok=True)
    for name, url in SOURCES.items():
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            print("downloading", url)
            urllib.request.urlretrieve(url, path)
    return {name: os.path.join(folder, name) for name in SOURCES}


def annotations(*paths):
    """Emoji (without variation selectors) -> (name, search words)."""
    out = {}
    for path in paths:
        for a in ET.parse(path).getroot().iter("annotation"):
            key = a.get("cp", "").replace("️", "")
            name, words = out.get(key, ("", []))
            text = (a.text or "").strip()
            if a.get("type") == "tts":
                name = text
            else:
                words = words + [w.strip() for w in text.split("|") if w.strip()]
            out[key] = (name, words)
    return out


def main():
    files = fetch(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "emoji-sources"))
    en = annotations(files["en.xml"], files["en-derived.xml"])
    he = annotations(files["he.xml"], files["he-derived.xml"])
    groups, entries = [], []
    line_re = re.compile(r"^([0-9A-F ]+?)\s*; fully-qualified\s*# (\S+) E(\d+\.\d+) (.+)$")
    for line in open(files["emoji-test.txt"], encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("# group: "):
            group = line[len("# group: "):]
            if group != "Component":
                groups.append(group)
            continue
        m = line_re.match(line)
        if not m or group == "Component" or float(m.group(3)) > MAX_VERSION:
            continue
        codes, emoji, name = m.group(1).split(), m.group(2), m.group(4)
        if TONES & set(codes):
            # A skin tone of the emoji before it: offered on a long press. Only one tone
            # (not two people with different tones).
            base = [c for c in codes if c not in TONES]
            if entries and ", " not in name and sum(c in TONES for c in codes) <= 2 and len(set(codes) & TONES) == 1:
                last = entries[-1]
                if [f"{ord(ch):X}" for ch in last["emoji"] if ch != "️"] == [c for c in base if c != "FE0F"]:
                    last["tones"].append(emoji)
            continue
        key = emoji.replace("️", "")
        en_name, en_words = en.get(key, ("", []))
        he_name, he_words = he.get(key, ("", []))
        entries.append({"emoji": emoji, "group": len(groups) - 1, "name": name.lower(),
                        "en": " ".join(dict.fromkeys(w.lower() for w in en_words if w.lower() != name.lower())),
                        "he": " | ".join(dict.fromkeys([he_name] + he_words if he_name else he_words)),
                        "tones": []})
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("# Lex emoji: made by scripts/make-emoji.py from Unicode emoji-test.txt and CLDR (Unicode license).\n")
        for i, g in enumerate(groups):
            f.write(f"#group\t{g}\n")
            for e in entries:
                if e["group"] == i:
                    f.write("\t".join([e["emoji"], e["name"], e["en"], e["he"], " ".join(e["tones"])]) + "\n")
    print(f"{len(entries)} emoji in {len(groups)} groups, {sum(len(e['tones']) > 0 for e in entries)} with skin tones -> {OUT}")


if __name__ == "__main__":
    main()
