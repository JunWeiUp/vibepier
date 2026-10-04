#!/usr/bin/env python3
"""Publish build-scoped artifacts without overwriting different bytes or provenance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def source():
    digest = hashlib.sha256()
    names = set(git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0'))
    for name in sorted(names - {b''}):
        path = ROOT / os.fsdecode(name)
        digest.update(name + b'\0')
        if path.is_symlink():
            digest.update(b'link\0' + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode & 0o777).encode() + b'\0')
            with path.open('rb') as stream:
                digest.update(hashlib.file_digest(stream, 'sha256').digest())
        else:
            digest.update(b'deleted')
    return {'commit': git('rev-parse', 'HEAD').decode().strip(),
            'dirty': bool(git('status', '--porcelain', '--untracked-files=normal').strip()),
            'sourceTreeSHA256': digest.hexdigest(),
            'version': (ROOT / 'VERSION').read_text().strip(),
            'build': int((ROOT / 'VERSION_CODE').read_text().strip())}


def collision():
    raise SystemExit('This build already has different artifact bytes or source. Increment VERSION_CODE before delivery.')


def existing_metadata(path, expected):
    if path.is_symlink():
        collision()
    if path.exists():
        try:
            if json.loads(path.read_text()) != expected:
                collision()
        except (OSError, ValueError):
            collision()


def claim_artifact(temporary, destination, digest):
    try:
        # The copied, flushed bytes atomically claim the name without replacement.
        os.link(temporary, destination)
    except FileExistsError:
        if destination.is_symlink() or not destination.is_file():
            collision()
        with destination.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                collision()


def claim_metadata(destination, value):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            json.dump(value, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
            os.chmod(temporary, 0o644)
            try:
                os.link(temporary, destination)
            except FileExistsError:
                existing_metadata(destination, value)
        finally:
            temporary.unlink(missing_ok=True)


def publish(snapshot, original, destination):
    before = json.loads(snapshot.read_text())
    if before != source():
        raise SystemExit('Source changed during packaging; rebuild from a stable checkout.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    sidecar = destination.with_name(destination.name + '.build.json')
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            # Hash the exact immutable copy that will be published. Shared staging
            # outputs may be rebuilt concurrently without changing tracked source.
            digest = hashlib.sha256()
            copied = 0
            with original.open('rb') as stream:
                initial = os.fstat(stream.fileno())
                while chunk := stream.read(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
                    copied += len(chunk)
                final = os.fstat(stream.fileno())
            fingerprint = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            if fingerprint(initial) != fingerprint(final) or copied != initial.st_size:
                raise SystemExit('Staged artifact changed while copying; rebuild before publishing.')
            output.flush()
            os.fsync(output.fileno())
            os.chmod(temporary, 0o644)
            value = {'artifact': destination.name, 'sha256': digest.hexdigest(), 'source': before,
                     'validation': {'artifactDigest': 'computed', 'deviceAcceptance': 'not_performed',
                                    'hostedCI': 'not_checked'}}
            # Refuse an orphaned or concurrent provenance claim too, even when
            # the artifact itself is absent. Existing metadata is never truncated.
            existing_metadata(sidecar, value)
            if before != source():
                raise SystemExit('Source changed during packaging; rebuild from a stable checkout.')
            claim_artifact(temporary, destination, value['sha256'])
            claim_metadata(sidecar, value)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    begin = sub.add_parser('begin')
    begin.add_argument('snapshot', type=Path)
    copy = sub.add_parser('publish')
    copy.add_argument('snapshot', type=Path)
    copy.add_argument('original', type=Path)
    copy.add_argument('destination', type=Path)
    args = parser.parse_args()
    if args.command == 'begin':
        args.snapshot.write_text(json.dumps(source(), indent=2) + '\n')
    else:
        publish(args.snapshot, args.original, args.destination)


if __name__ == '__main__':
    main()
