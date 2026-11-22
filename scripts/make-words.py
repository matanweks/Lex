#!/usr/bin/env python3
"""Builds the Lex keyboard's word lists: iOS/Keyboard/Data/{en,he}.words and {en,he}.next.

    python3 scripts/make-words.py [folder for the downloads]

  .words  one word per line with how common it is ("word<TAB>count"), most common first
  .next   a word, or two words, and the words that most often follow ("word<TAB>next next ...",
          "word word<TAB>next next ..."); the line for "" lists the words sentences usually
          start with. Sorted by the key's UTF-8 bytes, so the keyboard can look a key up in
          the file without reading it all into memory.

Sources (downloaded into the folder if they aren't there yet):
  - Tatoeba sentences, CC BY 2.0 FR (https://tatoeba.org): everyday English and Hebrew
    sentences, for the English words and for which word follows which
  - FrequencyWords by Hermit Dave, CC BY-SA 4.0 (https://github.com/hermitdave/FrequencyWords),
    from OpenSubtitles: the Hebrew words and how common they are
"""
import bz2
import collections
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "iOS", "Keyboard", "Data")
SOURCES = {
    "eng_sentences.tsv.bz2": "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2",
    "heb_sentences.tsv.bz2": "https://downloads.tatoeba.org/exports/per_language/heb/heb_sentences.tsv.bz2",
    "he_50k.txt": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/he/he_50k.txt",
}
# Tatoeba's sentences are famously about Tom and Mary (and a few other people, and Boston);
# they'd crowd out everyone else.
TATOEBA_NAMES = {n + s for n in ["tom", "mary", "sami", "layla", "ziri", "yanni", "skura", "rima", "mennad", "baya", "fadil",
                                 "dania", "salima", "taninna", "tatoeba"] for s in ["", "'s"]} | {"תום", "מרי", "סמי", "ליילה"}
RARER = {"boston": 20, "australia": 20, "john": 4, "algeria": 30, "algerian": 30, "algerians": 30, "kabylie": 30, "berber": 30, "french": 4}
HEBREW_PREFIXES = "ושהבלכמ"
WORD = {
    "en": re.compile(r"[a-z]+(?:'[a-z]+)*"),
    "he": re.compile(r"[א-ת]+(?:'[א-ת]+)*"),
}
# Punctuation ends a run of words: no "next word" across a comma or a full stop.
BREAK = re.compile(r"[.,!?;:()\[\]\"“”«»…–—/]+")


def fetch(folder):
    os.makedirs(folder, exist_ok=True)
    for name, url in SOURCES.items():
        path = os.path.join(folder, name)
        if not os.path.exists(path):
            print("downloading", url)
            urllib.request.urlretrieve(url, path)
    return {name: os.path.join(folder, name) for name in SOURCES}


def is_tatoeba_name(word, lang):
    if word in TATOEBA_NAMES:
        return True
    if lang == "he":
        # With a prefix: ותום, לתום, שמרי…
        for i in range(1, 3):
            if all(c in HEBREW_PREFIXES for c in word[:i]) and word[i:] in TATOEBA_NAMES:
                return True
    return False


def sentences(path):
    with bz2.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                yield parts[2]


def normalize(text, lang):
    text = text.replace("’", "'").replace("‘", "'").replace("׳", "'").replace("״", '"')
    return text.lower() if lang == "en" else text


def count(path, lang):
    """Word counts, for each word the counts of the words that follow it, and for each two
    words the counts of the words that follow them ("like to" → do, go, be)."""
    words, pairs, triples = collections.Counter(), collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    for sentence in sentences(path):
        start = True
        for run in BREAK.split(normalize(sentence, lang)):
            tokens = [t for t in run.split() if WORD[lang].fullmatch(t)]
            if not tokens:
                continue
            words.update(tokens)
            if start:
                pairs[""][tokens[0]] += 1
            for a, b in zip(tokens, tokens[1:]):
                pairs[a][b] += 1
            for a, b, c in zip(tokens, tokens[1:], tokens[2:]):
                triples[a + " " + b][c] += 1
            start = False
    return words, pairs, triples


def write(lang, words, pairs, triples, keep_words, keep_next, min_pair, keep_after_two, min_triple):
    for w, n in RARER.items():
        if w in words:
            words[w] //= n
    vocab = [(w, c) for w, c in words.most_common() if not is_tatoeba_name(w, lang) and (len(w) > 1 or w in ("a", "i"))][:keep_words]
    known = {w for w, _ in vocab}
    with open(os.path.join(OUT, f"{lang}.words"), "w", encoding="utf-8") as f:
        for w, c in vocab:
            f.write(f"{w}\t{c}\n")

    def likeliest(counter, least, keep):
        return [w for w, c in counter.most_common()
                if c >= least and w in known and not is_tatoeba_name(w, lang) and w not in RARER][:keep]

    lines = {}
    for prev in [""] + [w for w, _ in vocab]:
        nexts = likeliest(pairs.get(prev, collections.Counter()), min_pair, keep_next)
        if nexts:
            lines[prev] = nexts
    singles = len(lines)
    for two, counter in triples.items():
        a, b = two.split(" ")
        if a not in known or b not in known or is_tatoeba_name(a, lang) or is_tatoeba_name(b, lang) or sum(counter.values()) < 2 * min_triple:
            continue
        nexts = likeliest(counter, min_triple, keep_after_two)
        # Only where two words say more than the last one does.
        if nexts and nexts[:3] != lines.get(b, [])[:3]:
            lines[two] = nexts
    with open(os.path.join(OUT, f"{lang}.next"), "w", encoding="utf-8") as f:
        for key in sorted(lines, key=lambda k: k.encode("utf-8")):
            f.write(key + "\t" + " ".join(lines[key]) + "\n")
    print(f"{lang}: {len(vocab)} words, next words for {singles} words and {len(lines) - singles} pairs")


def main():
    files = fetch(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "word-sources"))
    os.makedirs(OUT, exist_ok=True)

    words, pairs, triples = count(files["eng_sentences.tsv.bz2"], "en")
    write("en", words, pairs, triples, keep_words=40_000, keep_next=10, min_pair=3, keep_after_two=6, min_triple=5)

    # Hebrew: how common each word is from subtitles (far more text than Tatoeba has in
    # Hebrew), which word follows which from Tatoeba.
    _, pairs, triples = count(files["heb_sentences.tsv.bz2"], "he")
    words = collections.Counter()
    for line in open(files["he_50k.txt"], encoding="utf-8"):
        word, _, n = line.strip().rpartition(" ")
        word = normalize(word, "he")
        if WORD["he"].fullmatch(word):
            words[word] += int(n)
    write("he", words, pairs, triples, keep_words=50_000, keep_next=10, min_pair=2, keep_after_two=6, min_triple=3)


if __name__ == "__main__":
    main()
