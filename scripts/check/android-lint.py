#!/usr/bin/env python3
"""Reject errors and new warnings; retain four visible, documented toolchain update notices."""
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
android = root / "apps/android"
report = android / "app/build/reports/lint-results-release.xml"
issues = ET.parse(report).getroot().findall("issue")
accepted, unexpected = [], []
for issue in issues:
    kind, message = issue.get("id"), issue.get("message", "")
    location = issue.find("location")
    path = Path(location.get("file", "")) if location is not None else Path()
    try:
        relative = path.resolve().relative_to(android).as_posix()
    except ValueError:
        relative = ""
    allowed = False
    if issue.get("severity") == "Warning":
        if relative == "app/build.gradle.kts":
            text = path.read_text()
            allowed = (
                kind == "OldTargetApi" and "targetSdk = 35" in text
                or kind == "GradleDependency" and "`compileSdkVersion` than 35" in message and "compileSdk = 35" in text
                or kind == "NewerVersionAvailable" and "org.json:json than 20250517" in message
                   and 'testImplementation("org.json:json:20250517")' in text
            )
        elif relative == "gradle/wrapper/gradle-wrapper.properties":
            allowed = kind == "AndroidGradlePluginVersion" and "Gradle than 8.13" in message and "gradle-8.13-bin.zip" in path.read_text()
    if allowed:
        accepted.append(kind)
    elif issue.get("severity") not in {"Information", "Informational", "Ignore"}:
        unexpected.append(f"{kind}: {relative or path.name}: {message}")
if unexpected:
    raise SystemExit("\n".join(unexpected))
print(f"PASS: no Lint errors or unreviewed warnings; {len(accepted)} documented version-update notices remain visible")
