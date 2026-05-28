import asyncio
import hmac
import os
import shutil
import uuid
from enum import Enum
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse


# Load .env from the bundler service's working dir if present. Real env vars
# (docker-compose `environment:`, systemd `EnvironmentFile=`) still win — this
# is just the fallback for plain `python -m uvicorn server:app` runs.
load_dotenv(override=False)


JOBS_DIR = Path(os.environ.get("BUNDLER_JOBS_DIR", "/jobs"))
SOURCE_DIR = Path(os.environ.get("BUNDLER_SOURCE_DIR", "/src"))
BUILD_SCRIPT = os.environ.get("BUNDLER_BUILD_SCRIPT", "/usr/local/bin/build.sh")
# Shared secret. The client POSTs a `token` form field with each /bundle call;
# if it doesn't match BUNDLER_TOKEN exactly, the job is rejected. Required —
# starting the service without a token is a misconfiguration, not a default.
BUNDLER_TOKEN = os.environ.get("BUNDLER_TOKEN", "").strip()
MAX_CONCURRENT = max(1, int(os.environ.get("BUNDLER_MAX_CONCURRENT", "1")))

if not BUNDLER_TOKEN:
    raise RuntimeError(
        "BUNDLER_TOKEN is not set. Put it in .env (or the systemd EnvironmentFile / "
        "docker-compose environment) — the service refuses to start without one."
    )

JOBS_DIR.mkdir(parents=True, exist_ok=True)


app = FastAPI(title="nes-bundler")
build_semaphore = asyncio.Semaphore(MAX_CONCURRENT)


class Status(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"


def check_token(token: str | None) -> None:
    # hmac.compare_digest avoids timing side-channels on the comparison.
    if not token or not hmac.compare_digest(token, BUNDLER_TOKEN):
        raise HTTPException(status_code=401, detail="invalid or missing token")


def write_status(job_dir: Path, status: Status, error: str | None = None) -> None:
    (job_dir / "status").write_text(status.value)
    if error:
        (job_dir / "error").write_text(error)


def read_status(job_dir: Path) -> Status:
    p = job_dir / "status"
    if not p.exists():
        return Status.QUEUED
    return Status(p.read_text().strip())


async def run_build(job_id: str) -> None:
    job_dir = JOBS_DIR / job_id
    async with build_semaphore:
        write_status(job_dir, Status.RUNNING)
        log_path = job_dir / "build.log"
        try:
            with log_path.open("wb") as log:
                proc = await asyncio.create_subprocess_exec(
                    BUILD_SCRIPT,
                    str(job_dir),
                    stdout=log,
                    stderr=asyncio.subprocess.STDOUT,
                )
                rc = await proc.wait()
        except Exception as e:
            write_status(job_dir, Status.FAILED, f"build launcher error: {e!r}")
            return
        bundle = job_dir / "bundle.tar.gz"
        if rc == 0 and bundle.exists():
            write_status(job_dir, Status.DONE)
        else:
            write_status(job_dir, Status.FAILED, f"build exited with code {rc}")


def _urls(request: Request, job_id: str) -> dict[str, str]:
    base = str(request.base_url).rstrip("/")
    return {
        "status_url": f"{base}/jobs/{job_id}",
        "download_url": f"{base}/jobs/{job_id}/download",
        "log_url": f"{base}/jobs/{job_id}/log",
    }


@app.post("/bundle")
async def create_bundle(
    request: Request,
    config: UploadFile,
    token: str = Form(...),
):
    check_token(token)

    job_id = uuid.uuid4().hex
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True)

    config_path = job_dir / "config.zip"
    with config_path.open("wb") as f:
        shutil.copyfileobj(config.file, f)

    write_status(job_dir, Status.QUEUED)
    asyncio.create_task(run_build(job_id))

    return {"job_id": job_id, "status": Status.QUEUED.value, **_urls(request, job_id)}


@app.get("/jobs/{job_id}")
async def get_job(job_id: str, request: Request):
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise HTTPException(404, "job not found")
    status = read_status(job_dir)
    body = {"job_id": job_id, "status": status.value, **_urls(request, job_id)}
    if status == Status.FAILED:
        err = job_dir / "error"
        if err.exists():
            body["error"] = err.read_text()
    return body


@app.get("/jobs/{job_id}/download")
async def download_bundle(job_id: str):
    job_dir = JOBS_DIR / job_id
    if not job_dir.exists():
        raise HTTPException(404, "job not found")
    bundle = job_dir / "bundle.tar.gz"
    if not bundle.exists():
        # If the job completed successfully, the artifact was purged by the
        # janitor (see bundler/cleanup.py + BUNDLER_BUNDLE_TTL_SECONDS).
        if read_status(job_dir) == Status.DONE:
            raise HTTPException(410, "bundle expired and was purged — see /log")
        raise HTTPException(404, "bundle not ready")
    # build.sh writes "${name}_${version}" here. Fallback to the opaque
    # job_id only for legacy jobs that predate this file.
    name_file = job_dir / "bundle.name"
    slug = name_file.read_text().strip() if name_file.exists() else f"nes-bundler-{job_id}"
    return FileResponse(
        bundle,
        media_type="application/gzip",
        filename=f"{slug}.tar.gz",
    )


@app.get("/jobs/{job_id}/log")
async def get_log(job_id: str):
    job_dir = JOBS_DIR / job_id
    log = job_dir / "build.log"
    if not log.exists():
        raise HTTPException(404, "log not found")
    return FileResponse(log, media_type="text/plain")


@app.get("/health")
async def health():
    return {"ok": True}
