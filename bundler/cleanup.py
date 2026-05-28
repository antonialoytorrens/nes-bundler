#!/usr/bin/env python3
"""Periodic janitor for nes-bundler job directories.

Two retention windows, both configurable via /etc/nesbundler/default:

  BUNDLER_BUNDLE_TTL_SECONDS (default 3600  = 1 h)
      How long the downloadable artifact (bundle.zip) is kept after
      the job dir was created. When this elapses, only the artifact is
      removed; the job's status + log are kept so users polling the job
      can see *why* their download disappeared.

  BUNDLER_JOB_TTL_SECONDS (default 604800 = 7 d)
      How long the entire job directory (status, log, per-job src tree,
      artifacts, bundle) is kept. After this, the whole job is purged.

Both purges append a clearly-marked WARNING line to the per-job build.log
before deleting anything, so the audit trail survives at least until the
job-level TTL.

Triggered by nesbundler-cleanup.timer (see deploy.sh).
"""

import os
import shutil
import sys
import time
from pathlib import Path

JOBS_DIR = Path(os.environ.get("BUNDLER_JOBS_DIR", "/var/lib/nesbundler/jobs"))
BUNDLE_TTL = int(os.environ.get("BUNDLER_BUNDLE_TTL_SECONDS", "3600"))
JOB_TTL = int(os.environ.get("BUNDLER_JOB_TTL_SECONDS", "604800"))


def _ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _append_log(log_path: Path, msg: str) -> None:
    try:
        with log_path.open("a") as f:
            f.write(f"[{_ts()}] WARNING: {msg}\n")
    except OSError:
        pass


def _purge_bundle(job_dir: Path, bundle: Path, age: int) -> bool:
    _append_log(
        job_dir / "build.log",
        f"bundle.zip purged after {age}s "
        f"(BUNDLER_BUNDLE_TTL_SECONDS={BUNDLE_TTL}). "
        f"Job metadata + log retained until job TTL "
        f"(BUNDLER_JOB_TTL_SECONDS={JOB_TTL}) elapses.",
    )
    try:
        bundle.unlink()
        return True
    except OSError as e:
        print(f"failed to unlink {bundle}: {e}", file=sys.stderr)
        return False


def _purge_job(job_dir: Path, age: int) -> bool:
    # Best-effort warning — gets removed with the rest immediately after, but
    # if rmtree fails for any reason at least the marker survives.
    _append_log(
        job_dir / "build.log",
        f"job directory purged after {age}s "
        f"(BUNDLER_JOB_TTL_SECONDS={JOB_TTL}).",
    )
    try:
        shutil.rmtree(job_dir)
        return True
    except OSError as e:
        print(f"failed to rmtree {job_dir}: {e}", file=sys.stderr)
        return False


def main() -> int:
    if not JOBS_DIR.exists():
        return 0
    now = time.time()
    bundles_purged = 0
    jobs_purged = 0

    for job_dir in JOBS_DIR.iterdir():
        if not job_dir.is_dir():
            continue
        try:
            job_age = int(now - job_dir.stat().st_mtime)
        except OSError:
            continue

        if job_age > JOB_TTL:
            if _purge_job(job_dir, job_age):
                jobs_purged += 1
            continue

        bundle = job_dir / "bundle.zip"
        if bundle.exists():
            try:
                bundle_age = int(now - bundle.stat().st_mtime)
            except OSError:
                continue
            if bundle_age > BUNDLE_TTL:
                if _purge_bundle(job_dir, bundle, bundle_age):
                    bundles_purged += 1

    print(
        f"[{_ts()}] cleanup: purged {bundles_purged} bundle(s), "
        f"{jobs_purged} job dir(s). "
        f"BUNDLE_TTL={BUNDLE_TTL}s JOB_TTL={JOB_TTL}s."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
