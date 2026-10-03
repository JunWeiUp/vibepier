#!/usr/bin/env python3
"""Check the translated Android resource contract; this does not certify all UI is migrated."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
resources = root / "apps/android/app/src/main/res"
errors = []


def read(folder):
    entries = {}
    for path in sorted((resources / folder).glob("*.xml")):
        for item in ET.parse(path).getroot():
            if item.tag not in {"string", "plurals", "string-array"}:
                continue
            name = item.get("name")
            if name in entries:
                errors.append(f"Duplicate resource in {folder}: {name}")
            entries[name] = item
    return entries


def placeholders(item, label):
    text = "".join(item.itertext())
    fields = set()
    for match in re.finditer(r"%(?:([1-9]\d*)\$)?[-#+ 0,(]*\d*(?:\.\d+)?([a-zA-Z%])", text):
        index, kind = match.groups()
        if kind in {"%", "n"}:
            continue
        if index is None:
            errors.append(f"Use indexed format arguments in {label}")
        fields.add((index, kind))
    return fields


english, chinese = read("values"), read("values-zh-rCN")
required = {name for name, value in english.items() if value.get("translatable") != "false"}
for name in sorted(required - chinese.keys()):
    errors.append(f"Missing Simplified Chinese resource: {name}")
for name in sorted(chinese.keys() - english.keys()):
    errors.append(f"Missing default resource: {name}")
for name in sorted(required & chinese.keys()):
    original, translated = english[name], chinese[name]
    if original.tag != translated.tag:
        errors.append(f"Resource kind differs: {name}")
        continue
    if placeholders(original, f"values/{name}") != placeholders(translated, f"values-zh-rCN/{name}"):
        errors.append(f"Format argument contract differs: {name}")
    if original.tag == "plurals":
        if not {"one", "other"} <= {item.get("quantity") for item in original}:
            errors.append(f"English plural needs one/other: {name}")
        if "other" not in {item.get("quantity") for item in translated}:
            errors.append(f"Chinese plural needs other: {name}")
    elif original.tag == "string-array":
        if len(original) != len(translated):
            errors.append(f"Translated array length differs: {name}")
        else:
            for index, (source_item, target_item) in enumerate(zip(original, translated)):
                if placeholders(source_item, name) != placeholders(target_item, name):
                    errors.append(f"Array item format contract differs: {name}[{index}]")

if errors:
    raise SystemExit("\n".join(errors))
print(f"PASS: {len(required)} English/zh-CN resource keys, kinds, format arguments and plural categories")
