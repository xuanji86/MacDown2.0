#!/usr/bin/env python3
"""Keeps the UI translations complete (run by `make test`).

Fails when
  - a string in App/Localizable.xcstrings has no zh-Hans translation;
  - a SwiftUI `Text("…")` / `Button("…")` / `Label("…")` / `Toggle("…")` / … , a `.help("…")` / `.accessibilityLabel("…")` and friends,
    or a `String(localized: "…")` in App/**/*.swift uses a key that is not in the catalog (so it would show untranslated);
  - a Chinese character is left in App/**/*.swift code outside comments (a line that must keep one, such as a language's own
    name, says `l10n: native-name` in a trailing comment);
  - one of the packages with their own words (WorkspaceKit, ExtensionAPI, QuartoExtension) has an en / zh-Hans Localizable.strings
    that do not list the same keys, an empty zh-Hans value, a key its code uses that is missing, or a Chinese literal in its code.

Use `Text(verbatim:)` for text that is not language (a glyph, a number), and add every new string to the catalog with both languages.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []

CJK = re.compile(r"[㐀-䶿一-鿿　-〿＀-￯]")
SPEC = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|f|lf|@)")
ALLOW = "l10n: native-name"

# Calls whose first string-literal argument is a localization key. (`Text(verbatim:)` is not matched: it has no leading quote.)
VIEW_CALLS = re.compile(
    r"(?<![\w.])(?:Text|Button|Label|Toggle|Picker|Section|Menu|Tab|TextField|SecureField|LabeledContent|DisclosureGroup|Stepper|"
    r"GroupBox|Link|SettingsLink)\(\s*\""
)
MODIFIER_CALLS = re.compile(r"\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog|navigationTitle)\(\s*\"")
NAMED_CALLS = re.compile(r"\.accessibilityAction\(named:\s*\"")
STRING_LOCALIZED = re.compile(r"String\(localized:\s*\"")
RESOURCE_CALLS = re.compile(r"L10n\.resource\(\s*\"")


def read_literal(text: str, start: int) -> tuple[str, int]:
    """`start` is the index of an opening quote. Returns (the literal's source between the quotes, index after the closing one).
    Interpolations are kept verbatim, nested literals included."""
    i = start + 1
    out = []
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            if text[i + 1] == "(":
                depth, j = 1, i + 2
                while j < len(text) and depth:
                    if text[j] == '"':
                        _, j = read_literal(text, j)
                        continue
                    depth += (text[j] == "(") - (text[j] == ")")
                    j += 1
                out.append(text[i:j])
                i = j
                continue
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == '"':
            return "".join(out), i + 1
        out.append(c)
        i += 1
    return "".join(out), i


def key_of(source: str) -> str:
    """The localization key Swift builds from a literal: interpolations become one placeholder, escapes are resolved."""
    out, i = [], 0
    while i < len(source):
        if source.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(source) and depth:
                if source[j] == '"':
                    _, j = read_literal(source, j)
                    continue
                depth += (source[j] == "(") - (source[j] == ")")
                j += 1
            out.append("%")
            i = j
        elif source[i] == "\\" and i + 1 < len(source):
            out.append(unescape(source[i:i + 2]))
            i += 2
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def unescape(escape: str) -> str:
    return {"\\n": "\n", "\\t": "\t", '\\"': '"', "\\\\": "\\", "\\'": "'", "\\r": "\r"}.get(escape, escape)


def norm(key: str) -> str:
    return SPEC.sub("%", key)


def code_without_comments(text: str) -> str:
    """The source with `//` comments blanked (string literals respected), so a pattern never matches inside a comment."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            _, j = read_literal(text, i)
            out.append(text[i:j])
            i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def literal_keys(code: str, patterns) -> list[tuple[int, str]]:
    found = []
    for pattern in patterns:
        for m in pattern.finditer(code):
            quote = m.end() - 1
            source, _ = read_literal(code, quote)
            found.append((code.count("\n", 0, quote) + 1, key_of(source)))
    return found


def cjk_lines(text: str, code: str, path: Path) -> None:
    lines, original = code.split("\n"), text.split("\n")
    for n, line in enumerate(lines, 1):
        if CJK.search(line) and ALLOW not in original[n - 1]:
            errors.append(f"{path.relative_to(ROOT)}:{n}: Chinese text in code; move it to the catalog ({line.strip()[:70]})")


# --------------------------------------------------------------------------- App (String Catalog)
def check_app() -> int:
    catalog_path = ROOT / "App" / "Localizable.xcstrings"
    strings = json.loads(catalog_path.read_text(encoding="utf-8"))["strings"]
    for key, entry in strings.items():
        zh = entry.get("localizations", {}).get("zh-Hans")
        if not zh or not has_text(zh):
            errors.append(f"App/Localizable.xcstrings: no zh-Hans translation for {key!r}")
    known = {norm(k) for k in strings}
    checked = 0
    for path in sorted((ROOT / "App").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        code = code_without_comments(text)
        cjk_lines(text, code, path)
        for line, key in literal_keys(code, [VIEW_CALLS, MODIFIER_CALLS, NAMED_CALLS, STRING_LOCALIZED]):
            checked += 1
            if norm(key) not in known:
                errors.append(f"{path.relative_to(ROOT)}:{line}: {key!r} is not in App/Localizable.xcstrings (add it with a zh-Hans translation, or use Text(verbatim:))")
    return checked


def has_text(localization: dict) -> bool:
    if "stringUnit" in localization:
        return bool(localization["stringUnit"].get("value", "").strip())
    variations = localization.get("variations", {})
    return any(has_text(v) for plural in variations.values() for v in plural.values())


# --------------------------------------------------------------------------- Packages (Localizable.strings)
PACKAGES = {
    "WorkspaceKit": "Packages/WorkspaceKit/Sources/WorkspaceKit",
    "ExtensionAPI": "Packages/ExtensionAPI/Sources/ExtensionAPI",
    "QuartoExtension": "Packages/QuartoExtension/Sources/QuartoExtension",
}
STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def read_strings(path: Path) -> dict[str, str]:
    table: dict[str, str] = {}
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        m = STRINGS_LINE.match(line)
        if not m:
            errors.append(f"{path.relative_to(ROOT)}:{n}: not a `\"key\" = \"value\";` line")
            continue
        table[re.sub(r"\\.", lambda e: unescape(e.group(0)), m.group(1))] = re.sub(r"\\.", lambda e: unescape(e.group(0)), m.group(2))
    return table


def check_packages() -> int:
    checked = 0
    for name, directory in PACKAGES.items():
        source = ROOT / directory
        en = read_strings(source / "Resources" / "en.lproj" / "Localizable.strings")
        zh = read_strings(source / "Resources" / "zh-Hans.lproj" / "Localizable.strings")
        for key in en.keys() ^ zh.keys():
            errors.append(f"{name}: {key!r} is not in both en.lproj and zh-Hans.lproj")
        for key, value in zh.items():
            if not value.strip():
                errors.append(f"{name}: empty zh-Hans translation for {key!r}")
        known = {norm(k) for k in zh}
        for path in sorted(source.glob("*.swift")):
            text = path.read_text(encoding="utf-8")
            code = code_without_comments(text)
            cjk_lines(text, code, path)
            for line, key in literal_keys(code, [VIEW_CALLS, STRING_LOCALIZED, RESOURCE_CALLS]):
                checked += 1
                if norm(key) not in known:
                    errors.append(f"{path.relative_to(ROOT)}:{line}: {key!r} is not in {name}'s Localizable.strings")
    return checked


app_checked = check_app()
package_checked = check_packages()
if errors:
    print("\n".join(errors), file=sys.stderr)
    print(f"check-localization: {len(errors)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"check-localization: ok ({app_checked} App and {package_checked} package strings checked)")
