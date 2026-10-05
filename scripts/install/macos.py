#!/usr/bin/env python3
"""Explicit, identity-preserving local Mac updates. Never changes TCC settings."""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

BUNDLE_ID = "io.github.junweiup.vibepier"
EXECUTABLE = "Contents/MacOS/VibePier"
HELPER = "Contents/MacOS/VibePierFileServer"
PROJECT = Path(__file__).resolve().parents[2]


class UpdateError(Exception):
    pass


def safe_path(path: Path, *, exists: bool = True) -> Path:
    """Reject links before resolving; resolve() alone would hide a linked parent."""
    if ".." in path.parts:
        raise UpdateError("Parent traversal is not accepted in paths")
    path = Path(os.path.abspath(path))
    for component in [*reversed(path.parents), path]:
        try:
            info = component.lstat()
        except FileNotFoundError:
            if exists or component != path:
                raise UpdateError(f"Path does not exist: {component}") from None
            continue
        if stat.S_ISLNK(info.st_mode):
            raise UpdateError(f"Symbolic links are not accepted: {component}")
    return path


def overlaps(a: Path, b: Path) -> bool:
    return a == b or a in b.parents or b in a.parents


def tree_manifest(path: Path) -> dict[str, tuple[int, str]]:
    """Bound the supported bundle to regular files/directories, with no links."""
    safe_path(path)
    if not path.is_dir():
        raise UpdateError(f"Expected a bundle directory: {path}")
    result: dict[str, tuple[int, str]] = {}
    for current, directories, files in os.walk(path, followlinks=False):
        for name in sorted(directories + files):
            entry = Path(current) / name
            info = entry.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise UpdateError(f"Bundle contains a link or special file: {entry}")
            digest = hashlib.sha256(entry.read_bytes()).hexdigest() if entry.is_file() else "directory"
            result[str(entry.relative_to(path))] = (stat.S_IMODE(info.st_mode), digest)
    return result


def bundle_info(path: Path) -> dict:
    try:
        info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise UpdateError(f"Invalid app Info.plist: {path}") from error
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "VibePier":
        raise UpdateError("Only the existing VibePier app identity can be updated")
    try:
        if int(info["CFBundleVersion"]) < 1:
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise UpdateError("CFBundleVersion must be a positive integer") from None
    if set(entry.name for entry in (path / "Contents/MacOS").iterdir()) != {"VibePier", "VibePierFileServer"}:
        raise UpdateError("Expected exactly the VibePier executable and bundled file helper")
    for relative in [EXECUTABLE, HELPER]:
        if not (path / relative).is_file() or not os.access(path / relative, os.X_OK):
            raise UpdateError(f"Missing executable: {relative}")
    return info


def leaf_fingerprint(path: Path) -> str | None:
    """Read the embedded leaf certificate through Security, without temporary files."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    signatures = [
        (cf, "CFURLCreateFromFileSystemRepresentation", [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool], ctypes.c_void_p),
        (security, "SecStaticCodeCreateWithPath", [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
        (security, "SecCodeCopySigningInformation", [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
        (cf, "CFDictionaryGetValue", [ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
        (cf, "CFArrayGetCount", [ctypes.c_void_p], ctypes.c_long),
        (cf, "CFArrayGetValueAtIndex", [ctypes.c_void_p, ctypes.c_long], ctypes.c_void_p),
        (security, "SecCertificateCopyData", [ctypes.c_void_p], ctypes.c_void_p),
        (cf, "CFDataGetLength", [ctypes.c_void_p], ctypes.c_long),
        (cf, "CFDataGetBytePtr", [ctypes.c_void_p], ctypes.POINTER(ctypes.c_ubyte)),
        (cf, "CFRelease", [ctypes.c_void_p], None),
    ]
    for library, name, arguments, returns in signatures:
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, returns
    raw = os.fsencode(path)
    url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), path.is_dir())
    code, information = ctypes.c_void_p(), ctypes.c_void_p()
    data = None
    try:
        if not url or security.SecStaticCodeCreateWithPath(url, 0, ctypes.byref(code)) != 0:
            raise UpdateError(f"Could not inspect signed code: {path}")
        if security.SecCodeCopySigningInformation(code, 2, ctypes.byref(information)) != 0:
            raise UpdateError(f"Could not read signing information: {path}")
        key = ctypes.c_void_p.in_dll(security, "kSecCodeInfoCertificates").value
        certificates = cf.CFDictionaryGetValue(information, key)
        if not certificates or cf.CFArrayGetCount(certificates) == 0:
            return None
        data = security.SecCertificateCopyData(cf.CFArrayGetValueAtIndex(certificates, 0))
        if not data:
            raise UpdateError("Could not read the signing certificate")
        raw = ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data))
        return hashlib.sha1(raw).hexdigest().upper()
    finally:
        for value in [data, information, code, url]:
            if value:
                cf.CFRelease(value)


@dataclass(frozen=True)
class Signature:
    identifier: str
    team: str
    leaf: str | None
    requirement: str
    entitlements: dict
    flags: int


class Backend:
    def run(self, arguments: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(arguments, capture_output=True, timeout=30)
        if check and result.returncode:
            raise UpdateError(f"{arguments[0]} failed: {result.stderr.decode(errors='replace')[:800].strip()}")
        return result

    def inspect(self, path: Path) -> Signature:
        self.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])
        details = self.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)]).stderr.decode()
        requirement_result = self.run(["/usr/bin/codesign", "-d", "-r-", str(path)])
        requirements = (requirement_result.stdout + requirement_result.stderr).decode()
        match = re.search(r"^#?\s*designated => (.+)$", requirements, re.MULTILINE)
        values = dict(re.findall(r"^(Identifier|TeamIdentifier)=(.*)$", details, re.MULTILINE))
        flags = re.search(r"flags=(0x[0-9a-fA-F]+)", details)
        if not match or not flags or not values.get("Identifier"):
            raise UpdateError(f"Incomplete code identity: {path}")
        encoded = self.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)]).stdout
        entitlements = plistlib.loads(encoded) if encoded else {}
        if not isinstance(entitlements, dict):
            raise UpdateError("Invalid signature entitlements")
        return Signature(values["Identifier"], values.get("TeamIdentifier", ""), leaf_fingerprint(path), match[1], entitlements, int(flags[1], 16))

    def identity_available(self, fingerprint: str) -> bool:
        identities = self.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).stdout.decode()
        return re.search(r"\b" + re.escape(fingerprint) + r"\b", identities) is not None

    def verify_identity(self, path: Path, expected: Signature) -> None:
        actual = self.inspect(path)
        if actual != expected:
            raise UpdateError(f"Signing identity, requirement, flags or entitlements changed: {path}")
        self.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + expected.requirement, str(path)])

    def sign(self, path: Path, expected: Signature, workspace: Path) -> None:
        entitlement_file = workspace / ("entitlements-" + expected.identifier.replace("/", "_") + ".plist")
        entitlement_file.write_bytes(plistlib.dumps(expected.entitlements))
        entitlement_file.chmod(0o600)
        # Existing signatures may only have ad-hoc/runtime bits. Runtime is preserved;
        # ad-hoc is replaced by the installed certificate, never by a newly selected one.
        if expected.flags & ~0x10000:
            raise UpdateError("Unsupported installed signing flags; refuse to change them")
        arguments = ["/usr/bin/codesign", "--force", "--timestamp=none", "--identifier", expected.identifier,
                     "--requirements", "=designated => " + expected.requirement,
                     "--entitlements", str(entitlement_file), "--sign", expected.leaf or ""]
        if expected.flags & 0x10000:
            arguments += ["--options", "runtime"]
        self.run(arguments + [str(path)])

    def executable_pids(self, target: Path, *, include_helper: bool = True) -> list[int]:
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        result = self.run(["/bin/ps", "-axo", "pid="])
        known = {os.fsencode(target / EXECUTABLE)}
        if include_helper:
            known.add(os.fsencode(target / HELPER))
        pids = []
        for raw in result.stdout.split():
            pid = int(raw)
            buffer = ctypes.create_string_buffer(4096)
            if library.proc_pidpath(pid, buffer, len(buffer)) > 0 and buffer.value in known:
                pids.append(pid)
        return pids

    def stop(self, target: Path, plist: Path) -> bool:
        label = f"gui/{os.getuid()}/{BUNDLE_ID}"
        loaded = self.run(["/bin/launchctl", "print", label], check=False).returncode == 0
        if loaded:
            self.run(["/bin/launchctl", "bootout", label])
            deadline = time.monotonic() + 15
            while self.run(["/bin/launchctl", "print", label], check=False).returncode == 0:
                if time.monotonic() > deadline:
                    raise UpdateError("LaunchAgent did not finish unloading; app was not modified")
                time.sleep(0.1)
        for pid in self.executable_pids(target):
            # Recheck immediately before signalling to limit PID reuse risk.
            if pid in self.executable_pids(target):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 15
        while self.executable_pids(target):
            if time.monotonic() > deadline:
                raise UpdateError("App/helper is still running; app was not modified")
            time.sleep(0.1)
        return loaded

    def resume(self, plist: Path) -> None:
        label = f"gui/{os.getuid()}/{BUNDLE_ID}"
        if self.run(["/bin/launchctl", "print", label], check=False).returncode != 0:
            self.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)])
            self.run(["/bin/launchctl", "kickstart", label])

    def verify_running(self, target: Path) -> None:
        deadline = time.monotonic() + 15
        while not self.executable_pids(target, include_helper=False):
            if time.monotonic() > deadline:
                raise UpdateError("Updated app did not remain running after service restart")
            time.sleep(0.1)
        # A bootstrap success alone does not rule out an immediate signature kill.
        time.sleep(1)
        if not self.executable_pids(target, include_helper=False):
            raise UpdateError("Updated app exited immediately after service restart")


@dataclass
class Plan:
    source: Path
    target: Path
    old: Signature
    old_helper: Signature
    needs_signing: bool
    source_manifest: dict
    target_manifest: dict
    target_inode: tuple[int, int]
    old_build: int
    new_build: int


def preflight(source: Path, target: Path, backend: Backend) -> Plan:
    source, target = safe_path(source), safe_path(target)
    if target.name != "VibePier.app" or overlaps(source, target):
        raise UpdateError("Use a separate source and the fixed VibePier.app target")
    source_manifest, target_manifest = tree_manifest(source), tree_manifest(target)
    new_info, old_info = bundle_info(source), bundle_info(target)
    old = backend.inspect(target)
    old_helper = backend.inspect(target / HELPER)
    if not old.leaf or "cdhash" in old.requirement or old.identifier != BUNDLE_ID:
        raise UpdateError("Installed app must already have a stable certificate identity; no automatic migration")
    if not old_helper.leaf or old_helper.leaf != old.leaf or "cdhash" in old_helper.requirement:
        raise UpdateError("Installed file helper must use the app's stable certificate")
    candidate = backend.inspect(source)
    helper = backend.inspect(source / HELPER)
    needs_signing = candidate.leaf is None
    if needs_signing:
        if helper.leaf is not None or candidate.identifier != old.identifier or helper.identifier != old_helper.identifier:
            raise UpdateError("Only an ad-hoc app and helper with the same identifiers can be prepared")
        if not backend.identity_available(old.leaf):
            raise UpdateError("The exact installed signing certificate/private key is unavailable; no fallback")
    else:
        backend.verify_identity(source, old)
        backend.verify_identity(source / HELPER, old_helper)
    old_build, new_build = int(old_info["CFBundleVersion"]), int(new_info["CFBundleVersion"])
    if new_build < old_build:
        raise UpdateError("Refusing a build-number downgrade")
    info = target.stat()
    return Plan(source, target, old, old_helper, needs_signing, source_manifest, target_manifest,
                (info.st_dev, info.st_ino), old_build, new_build)


def copy_candidate(plan: Plan, output: Path, workspace: Path, backend: Backend) -> None:
    if tree_manifest(plan.source) != plan.source_manifest:
        raise UpdateError("Source changed after preflight")
    shutil.copytree(plan.source, output, copy_function=shutil.copy2)
    if tree_manifest(output) != plan.source_manifest or tree_manifest(plan.source) != plan.source_manifest:
        raise UpdateError("Source changed while copying")
    if plan.needs_signing:
        backend.sign(output / HELPER, plan.old_helper, workspace)
        backend.sign(output, plan.old, workspace)
    backend.verify_identity(output / HELPER, plan.old_helper)
    backend.verify_identity(output, plan.old)


def prepare(plan: Plan, output: Path, backend: Backend) -> None:
    output = safe_path(output, exists=False)
    if output.exists() or output.name != "VibePier.app" or Path("/Applications") in output.parents:
        raise UpdateError("Prepare output must be a new VibePier.app outside /Applications")
    if overlaps(output, plan.source) or overlaps(output, plan.target):
        raise UpdateError("Prepare output overlaps the source or installed app")
    with tempfile.TemporaryDirectory(prefix=".vibepier-sign-", dir=output.parent) as temporary:
        try:
            copy_candidate(plan, output, Path(temporary), backend)
        except BaseException:
            if output.exists():
                shutil.rmtree(output)
            raise


def replace_in_place(target: Path, candidate: Path) -> None:
    """Overlay first, then prune: retain .app/Contents/Info.plist identities."""
    safe_path(target)
    existing, desired = tree_manifest(target), tree_manifest(candidate)
    for relative in existing.keys() & desired.keys():
        if (existing[relative][1] == "directory") != (desired[relative][1] == "directory"):
            raise UpdateError(f"Bundle entry changes file/directory type: {relative}")
    # Bundle/Contents/Info remain at the same inode. Signed executable bytes must
    # use new inodes: writing through their old inode leaves stale kernel signing
    # caches even when on-disk codesign validation succeeds (Updating Mac Software).
    for relative, (mode, digest) in sorted(desired.items(), key=lambda value: (len(Path(value[0]).parts), value[0])):
        source, destination = candidate / relative, target / relative
        if digest == "directory":
            destination.mkdir(exist_ok=True)
            destination.chmod(mode)
        elif relative in {EXECUTABLE, HELPER}:
            replace_executable(source, destination)
        else:
            shutil.copy2(source, destination)
    for relative in sorted(existing.keys() - desired.keys(), key=lambda value: len(Path(value).parts), reverse=True):
        destination = target / relative
        if existing[relative][1] == "directory":
            destination.rmdir()
        else:
            destination.unlink()
    if tree_manifest(target) != desired:
        raise UpdateError("Updated bundle contents do not match the verified candidate")


def replace_executable(source: Path, destination: Path) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".vibepier-code-", dir=destination.parent)
    os.close(descriptor)
    try:
        shutil.copy2(source, temporary)
        with open(temporary, "rb") as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def association_update(original: bytes, target: Path) -> bytes | None:
    info = plistlib.loads(original)
    arguments = info.get("ProgramArguments")
    expected = str(target / EXECUTABLE)
    if (info.get("Label") != BUNDLE_ID or not isinstance(arguments, list) or not arguments
            or arguments[0] != expected or info.get("Program", expected) != expected):
        raise UpdateError("Existing LaunchAgent does not launch the fixed target; refuse to change it")
    associated = info.get("AssociatedBundleIdentifiers", [])
    if isinstance(associated, str):
        associated = [associated]
    if not isinstance(associated, list) or not all(isinstance(value, str) for value in associated):
        raise UpdateError("Invalid existing LaunchAgent bundle association")
    if BUNDLE_ID in associated:
        return None
    info["AssociatedBundleIdentifiers"] = associated + [BUNDLE_ID]
    return plistlib.dumps(info, sort_keys=False)


def preserved_files(target: Path) -> tuple[Path, dict[Path, str], bytes | None]:
    plist = safe_path(Path.home() / "Library/LaunchAgents" / (BUNDLE_ID + ".plist"))
    updated = association_update(plist.read_bytes(), target)
    paths = [plist, Path.home() / "Library/Application Support/vibepier/config.json"]
    hashes = {}
    for path in paths:
        safe_path(path)
        if not path.is_file():
            raise UpdateError(f"Expected an existing regular settings file: {path}")
        hashes[path] = hashlib.sha256(path.read_bytes()).hexdigest()
    return plist, hashes, updated


def assert_preserved(hashes: dict[Path, str]) -> None:
    for path, expected in hashes.items():
        safe_path(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise UpdateError(f"Existing settings changed during update: {path}")


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    safe_path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".vibepier-update-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def update_lock_directory() -> Path:
    return Path.home() / "Library/Application Support/vibepier/macos-update-locks"


def private_directory(path: Path) -> Path:
    path = Path(os.path.abspath(path))
    safe_path(path.parent)
    if not path.exists():
        path.mkdir(mode=0o700)
    safe_path(path)
    info = path.stat()
    if not path.is_dir() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise UpdateError("Update directories must be private, owned directories with mode 0700")
    return path


def apply(plan: Plan, backup_root: Path, backend: Backend) -> Path:
    backup_root = Path(os.path.abspath(backup_root))
    if any(overlaps(backup_root, path) for path in [plan.source, plan.target]):
        raise UpdateError("Backup directory overlaps an app bundle")
    backup_root = private_directory(backup_root)
    lock_directory = private_directory(update_lock_directory())
    # Every update of the same target shares this lock, regardless of backup choice.
    lock_name = hashlib.sha256(os.fsencode(plan.target)).hexdigest() + ".lock"
    lock = os.open(lock_directory / lock_name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise UpdateError("Unsafe update lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise UpdateError("Another Mac update is running") from None
        return apply_locked(plan, backup_root, backend)
    finally:
        os.close(lock)


def apply_locked(plan: Plan, backup_root: Path, backend: Backend) -> Path:
    plist, hashes, associated = preserved_files(plan.target)
    original_plist = plist.read_bytes()
    plist_mode = stat.S_IMODE(plist.stat().st_mode)
    work = Path(tempfile.mkdtemp(prefix="update-", dir=backup_root))
    candidate, previous = work / "VibePier.app", work / "previous-bundle"
    copy_candidate(plan, candidate, work, backend)
    if tree_manifest(plan.target) != plan.target_manifest:
        raise UpdateError("Installed app changed after preflight")
    shutil.copytree(plan.target, previous, copy_function=shutil.copy2)
    if tree_manifest(previous) != plan.target_manifest:
        raise UpdateError("Could not verify the backup")
    backend.verify_identity(previous, plan.old)
    (work / "previous-launch-agent.plist").write_bytes(original_plist)
    (work / "previous-launch-agent.plist").chmod(0o600)
    stopped = False
    modified = False
    plist_modified = False
    restart_attempted = False
    try:
        # Record loaded state first, so a partially failed stop can restart the original service.
        label = f"gui/{os.getuid()}/{BUNDLE_ID}"
        stopped = backend.run(["/bin/launchctl", "print", label], check=False).returncode == 0
        if not stopped and backend.executable_pids(plan.target):
            raise UpdateError("The app/helper was started manually; quit it before applying this update")
        backend.stop(plan.target, plist)
        info = plan.target.stat()
        if (info.st_dev, info.st_ino) != plan.target_inode or tree_manifest(plan.target) != plan.target_manifest:
            raise UpdateError("Installed app changed while stopping; refuse replacement")
        assert_preserved(hashes)
        modified = True
        replace_in_place(plan.target, candidate)
        info = plan.target.stat()
        if (info.st_dev, info.st_ino) != plan.target_inode:
            raise UpdateError("Installed app directory identity changed")
        backend.verify_identity(plan.target / HELPER, plan.old_helper)
        backend.verify_identity(plan.target, plan.old)
        assert_preserved(hashes)
        if associated is not None:
            plist_modified = True
            atomic_write(plist, associated, plist_mode)
            hashes[plist] = hashlib.sha256(associated).hexdigest()
        assert_preserved(hashes)
        if stopped:
            restart_attempted = True
            backend.resume(plist)
            backend.verify_running(plan.target)
    except BaseException as error:
        try:
            if restart_attempted:
                backend.stop(plan.target, plist)
            if modified:
                replace_in_place(plan.target, previous)
                backend.verify_identity(plan.target, plan.old)
            if plist_modified:
                atomic_write(plist, original_plist, plist_mode)
            if stopped:
                backend.resume(plist)
                backend.verify_running(plan.target)
        except BaseException as rollback_error:
            raise UpdateError(f"Update failed and restore needs attention. Backup: {previous}; {rollback_error}") from error
        raise
    receipt = {"updated": True, "app": str(plan.target), "backup": str(previous),
               "oldBuild": plan.old_build, "newBuild": plan.new_build, "bundleDirectoryPreserved": True,
               "sameSigningIdentity": True, "settingsPreserved": True, "cliUpdated": False,
               "launchAgentAssociationUpdated": associated is not None,
               "fullDiskAccess": "not independently verified"}
    with (work / "receipt.json").open("x") as handle:
        json.dump(receipt, handle, indent=2)
        handle.write("\n")
    (work / "receipt.json").chmod(0o600)
    return previous


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Default/--dry-run performs read-only signature/path checks; it never signs, stops or launches apps. "
        "--prepare-output copies/signs only that new output, without changing the installation. "
        "--apply explicitly updates the app in place and restarts an already-loaded original LaunchAgent. "
        "The CLI, configuration and system permissions are not changed. The verified existing LaunchAgent "
        "may only gain this app's AssociatedBundleIdentifiers entry; all other fields are preserved. "
        "Full Disk Access retention needs user verification; code-signature validation does not prove a TCC grant."))
    parser.add_argument("--source", type=Path, default=PROJECT / "dist/staging/VibePier.app", help="Built source app (default: dist/staging/VibePier.app)")
    parser.add_argument("--target", type=Path, default=Path("/Applications/VibePier.app"), help="Existing VibePier.app to preserve (default: /Applications/VibePier.app)")
    parser.add_argument("--backup-root", type=Path, default=Path.home() / "Library/Application Support/vibepier/macos-updates", help="Private 0700 backup directory for --apply")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Read-only checks (also the default)")
    mode.add_argument("--prepare-output", type=Path, metavar="NEW_VIBEPIER_APP", help="Copy and sign a new VibePier.app outside /Applications; do not install or run it")
    mode.add_argument("--apply", action="store_true", help="Explicitly stop and update the existing app, preserving its top-level directory")
    args = parser.parse_args(arguments)
    if sys.platform != "darwin":
        parser.error("This installer requires macOS; isolated unit tests remain portable")
    try:
        backend = Backend()
        plan = preflight(args.source, args.target, backend)
        _, _, associated = preserved_files(plan.target)
        summary = {"mode": "dry-run", "source": str(plan.source), "target": str(plan.target),
                   "oldBuild": plan.old_build, "newBuild": plan.new_build, "requiresPreparation": plan.needs_signing,
                   "sameInstalledCertificate": plan.old.leaf, "cliUpdated": False,
                   "launchAgentAssociationNeedsUpdate": associated is not None,
                   "fullDiskAccess": "not independently verified"}
        if args.prepare_output:
            prepare(plan, args.prepare_output, backend)
            summary.update(mode="prepare-only", preparedApp=str(Path(os.path.abspath(args.prepare_output))))
        elif args.apply:
            backup = apply(plan, args.backup_root, backend)
            summary.update(mode="apply", backup=str(backup), bundleDirectoryPreserved=True)
        print(json.dumps(summary, indent=2))
        return 0
    except (UpdateError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Mac update refused/failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
