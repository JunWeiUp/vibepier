#!/usr/bin/env python3
"""Explicit read-only native acceptance. Never enables mutation or installs an app."""
import argparse
import os
from pathlib import Path
import signal
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opt-in", action="store_true", required=True)
    parser.add_argument("--probe", choices=["catalogs", "creation-preflight"], default="catalogs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    case = {"catalogs": "testReadOnlyModelCatalogs",
            "creation-preflight": "testFreshWorkspaceCreationPreflight"}[args.probe]
    env = dict(os.environ, VIBEPIER_NATIVE_ACCEPTANCE="1")
    env.pop("VIBEPIER_NATIVE_MUTATIONS", None)
    process = subprocess.Popen([
        "swift", "test", "--package-path", str(root / "apps/macos"),
        "--filter", "NativeAdapterAcceptanceTests/" + case,
    ], cwd=root, env=env, start_new_session=True)
    try:
        return process.wait(timeout=180)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        print("NATIVE_PROBE stopped; no automatic retry")
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
