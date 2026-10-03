#!/usr/bin/env python3
"""Write a version/digest sidecar for a built APK; never registers or installs it."""
import hashlib
import json
from pathlib import Path
import sys

apk = Path(sys.argv[1]).resolve()
metadata = json.loads((apk.parent / 'output-metadata.json').read_text())
assert metadata['applicationId'] == 'io.github.junweiup.vibepier.remote'
element = next(v for v in metadata['elements'] if v['outputFile'] == apk.name)
value = {'packageName': metadata['applicationId'], 'versionCode': element['versionCode'],
         'versionName': element['versionName'], 'sha256': hashlib.file_digest(apk.open('rb'), 'sha256').hexdigest()}
apk.with_suffix('.apk.json').write_text(json.dumps(value, indent=2) + '\n')
