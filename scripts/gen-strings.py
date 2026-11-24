#!/usr/bin/env python3
"""Regenerate Raft/Localizable.xcstrings from the L10n calls in Raft/.

Every `L10n.t("key", "Fallback")` / `L10n.f("key", "Fallback", …)` becomes an entry whose
English value is the fallback in code. The code is the source of truth for English.

Simplified Chinese comes from the legacy Compose client's strings.xml when that key exists
there and its English matches ours. If the English differs, the old translation probably
says something else, so it is skipped (and listed with --verbose). `ios_*` keys are new to
this client: English only until someone translates them. Keys that are not found fall back
to English at runtime (NSLocalizedString's `value:`).

Entries already in the catalog that are not L10n keys (for example "Made with AirBuild") are
kept as they are, and so are zh-Hans values that were edited by hand (state "translated"
without the generator's comment marker).

    python3 scripts/gen-strings.py [--legacy <composeResources dir>] [--verbose]
"""
import argparse
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Raft")
CATALOG = os.path.join(SOURCES, "Localizable.xcstrings")
MARK = "gen-strings"

CALL = re.compile(r'L10n\.([tf])\(\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*"((?:[^"\\]|\\.)*)")?')


def swift_unescape(s):
    def repl(m):
        e = m.group(1)
        if e.startswith("u{"):
            return chr(int(e[2:-1], 16))
        return {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(e, e)
    return re.sub(r'\\(u\{[0-9A-Fa-f]+\}|.)', repl, s)


def scan():
    keys = {}
    conflicts = []
    for base, _, files in os.walk(SOURCES):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            text = open(path, encoding="utf-8").read()
            for m in CALL.finditer(text):
                key = swift_unescape(m.group(2))
                fallback = swift_unescape(m.group(3)) if m.group(3) is not None else None
                line = text.count("\n", 0, m.start()) + 1
                where = f"{os.path.relpath(path, ROOT)}:{line}"
                if key in keys:
                    old = keys[key]
                    if fallback is not None and old["fallback"] is not None and old["fallback"] != fallback:
                        conflicts.append((key, old["fallback"], fallback, where))
                    if old["fallback"] is None:
                        old["fallback"] = fallback
                    old["sites"].append(where)
                else:
                    keys[key] = {"fallback": fallback, "sites": [where]}
    return keys, conflicts


def android_to_apple(s):
    s = s.strip()
    if s.startswith('"') and s.endswith('"') and len(s) >= 2:
        s = s[1:-1]
    s = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", s, flags=re.S)
    s = html.unescape(s)
    s = s.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\@", "@").replace("\\?", "?")
    s = re.sub(r"%(\d+\$)?s", lambda m: "%" + (m.group(1) or "") + "@", s)
    return s


def load_legacy(folder, values):
    path = os.path.join(folder, values, "strings.xml")
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    return {m.group(1): android_to_apple(m.group(2))
            for m in re.finditer(r'<string name="([^"]+)"[^>]*>(.*?)</string>', text, re.S)}


def norm(s):
    return re.sub(r"[\s.…!?:;,'’\"“”]+", " ", s).strip().lower()


def placeholders(s):
    return sorted(re.findall(r"%(?:\d+\$)?[@dlfsu]+", s))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--legacy", help="legacy composeResources dir (values/, values-zh-rCN/)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    keys, conflicts = scan()
    catalog = json.load(open(CATALOG, encoding="utf-8")) if os.path.exists(CATALOG) else {
        "sourceLanguage": "en", "strings": {}, "version": "1.0"}
    strings = catalog.setdefault("strings", {})

    legacy_en = legacy_zh = {}
    if args.legacy:
        legacy_en = load_legacy(args.legacy, "values")
        legacy_zh = load_legacy(args.legacy, "values-zh-rCN")

    stats = {"keys": len(keys), "zh": 0, "zh_kept": 0, "ios": 0, "legacy_missing": [], "mismatch": [], "no_fallback": []}
    for key, info in sorted(keys.items()):
        english = info["fallback"]
        if english is None:
            english = legacy_en.get(key)
            if english is None:
                stats["no_fallback"].append(key)
                english = key
        previous = strings.get(key, {})
        entry = {"comment": f"{MARK}: {', '.join(info['sites'][:3])}", "extractionState": "manual"}
        localizations = {"en": {"stringUnit": {"state": "translated", "value": english}}}

        old_zh = previous.get("localizations", {}).get("zh-Hans")
        hand_edited = old_zh is not None and not previous.get("comment", "").startswith(MARK)
        zh = None
        if key.startswith("ios_"):
            stats["ios"] += 1
        elif args.legacy:
            if key not in legacy_en:
                stats["legacy_missing"].append(key)
            elif norm(legacy_en[key]) != norm(english):
                stats["mismatch"].append((key, legacy_en[key], english))
            elif key in legacy_zh and placeholders(legacy_zh[key]) == placeholders(english):
                zh = legacy_zh[key]
        if hand_edited or (zh is None and old_zh is not None and not args.legacy):
            localizations["zh-Hans"] = old_zh
            stats["zh_kept"] += 1
        elif zh is not None:
            localizations["zh-Hans"] = {"stringUnit": {"state": "translated", "value": zh}}
            stats["zh"] += 1
        entry["localizations"] = localizations
        strings[key] = entry

    # Drop generated entries whose key is no longer used; keep everything else.
    for key in [k for k, v in strings.items() if k not in keys and v.get("comment", "").startswith(MARK)]:
        del strings[key]

    with open(CATALOG, "w", encoding="utf-8") as out:
        json.dump(catalog, out, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        out.write("\n")

    print(f"{stats['keys']} keys · zh-Hans {stats['zh']} from legacy, {stats['zh_kept']} kept · {stats['ios']} ios_* (English only)")
    print(f"not in legacy: {len(stats['legacy_missing'])} · English differs from legacy: {len(stats['mismatch'])} · no fallback: {len(stats['no_fallback'])}")
    for key, a, b, where in conflicts:
        print(f"CONFLICT {key}: {a!r} vs {b!r} at {where}", file=sys.stderr)
    if args.verbose:
        for key in stats["legacy_missing"]:
            print("  not in legacy:", key)
        for key, old, new in stats["mismatch"]:
            print(f"  differs: {key}: legacy {old!r} / ours {new!r}")
        for key in stats["no_fallback"]:
            print("  no fallback:", key)
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main())
