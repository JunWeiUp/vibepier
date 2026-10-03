#!/usr/bin/env python3
"""Check publishable files only, never private caches, logs or local handoff material."""
from pathlib import Path
from urllib.parse import unquote
import hashlib
import hmac
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
files = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT
).decode().split("\0")
files = {name for name in files if name}
errors = []
required = {
    "AGENTS.md", "README.md", "README.zh-CN.md", "DESIGN.md", "CHANGELOG.md", "TODO.md",
    "CONTRIBUTING.md", "LICENSE", "NOTICE", "SECURITY.md", "scripts/build/macos.sh",
    "docs/README.md", "docs/PROJECT-SPEC.md", "docs/ARCHITECTURE.md", "docs/COMPONENT-GUIDELINES.md",
    "docs/PAGE-STRUCTURE.md", "docs/DEVELOPMENT.md", "docs/REGISTRY.md", "docs/DEPLOYMENT.md",
    "docs/SETUP.md", "docs/MIGRATION.md", "docs/COMPATIBILITY.md", "docs/PROVENANCE.md",
    "docs/launch/article.zh-CN.md", "docs/launch/article.en.md", "docs/launch/community-posts.md",
}
for missing in sorted(required - files):
    errors.append(f"Missing/ignored required file: {missing}")

version = (ROOT / "VERSION").read_text().strip()
cli = (ROOT / "apps/macos/Sources/VibePierCore/Runtime/CLI.swift").read_text()
cli_version = re.search(r'print\("vibepier ([^"]+)"\)', cli)
if cli_version is None or cli_version.group(1) != version:
    errors.append("CLI version differs from VERSION")

for name in sorted(files):
    path = ROOT / name
    if path.is_symlink() and not path.resolve().is_relative_to(ROOT):
        errors.append(f"External symlink: {name}")
        continue
    if not path.is_file():
        errors.append(f"Missing file: {name}")
        continue
    if name.startswith((".local/", "dist/")) or path.suffix.lower() in {".jks", ".keystore", ".p12", ".p8", ".mobileprovision", ".pyc", ".pyo"}:
        errors.append(f"Private/generated artifact in publication: {name}")
    if path.suffix.lower() == ".md":
        text = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)
        links = re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', text) + re.findall(r'(?:src|href)="([^"]+)"', text)
        for link in links:
            link = link.split(' "', 1)[0].strip("<>")
            if not link or re.match(r"^[a-z][a-z0-9+.-]*:", link, re.I) or link.startswith("#"):
                continue
            target = path.parent / unquote(link.split("#", 1)[0])
            if not target.exists():
                errors.append(f"Broken local Markdown path in {name}: {link}")
            elif target.is_file() and target.resolve().is_relative_to(ROOT) and target.resolve().relative_to(ROOT).as_posix() not in files:
                errors.append(f"Markdown link targets an ignored file in {name}: {link}")
    if path.suffix.lower() in {".swift", ".kt", ".go", ".sh", ".kts"}:
        source = path.read_text()
        if re.search(r"/Users/(?!demo/|example/)[^/\s]+/", source):
            errors.append(f"Personal home path in source: {name}")
        if name.startswith("apps/android/app/src/main/") and path.suffix == ".kt" and path.name != "TransportLog.kt":
            if re.search(r"\bandroid\.util\.Log\b|(?<![\w.])Log\.[vdiwef]\s*\(|\bprintStackTrace\s*\(|\bSystem\.(?:out|err)\b", source):
                errors.append(f"Route production diagnostics through fixed TransportLog categories: {name}")

vectors = json.loads((ROOT / "protocol/fixtures/relay-hello.json").read_text())
assert len(vectors) == 3
for vector in vectors:
    payload = "|".join(str(vector[key]) for key in ("protocol", "role", "room", "timestamp", "nonce"))
    expected = hmac.new(vector["secret"].encode(), payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, vector["hmac"]):
        errors.append("Invalid relay hello fixture signature")

control = dict(line.split("=", 1) for line in (ROOT / "protocol/fixtures/control-v1.properties").read_text().splitlines() if line and not line.startswith("#"))
root_key = bytes.fromhex(control["rootHex"])
prk = hmac.new(bytes(32), root_key, hashlib.sha256).digest()
for purpose in ("handshake", "phone", "mac"):
    derived = hmac.new(prk, f"vibepier-control-v1/{purpose}".encode() + b"\x01", hashlib.sha256).hexdigest()
    if not hmac.compare_digest(derived, control[purpose + "KeyHex"]):
        errors.append(f"Invalid control {purpose} fixture")
for name in ("hello", "ready"):
    fields = control[name].split(" ")
    expected = hmac.new(bytes.fromhex(control["handshakeKeyHex"]), "|".join(fields[:-1]).encode(), hashlib.sha256).hexdigest()
    if len(fields) != 7 or not hmac.compare_digest(expected, fields[-1]):
        errors.append(f"Invalid negotiated control {name} fixture")

if errors:
    raise SystemExit("\n".join(errors))
print(f"PASS: {len(files)} publishable files, local doc paths, private-path/artifact exclusions and shared HMAC/HKDF fixtures")
