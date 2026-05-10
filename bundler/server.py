import asyncio
import os
import shutil
import uuid
from enum import Enum
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse


JOBS_DIR = Path(os.environ.get("BUNDLER_JOBS_DIR", "/jobs"))
SOURCE_DIR = Path(os.environ.get("BUNDLER_SOURCE_DIR", "/src"))
BUILD_SCRIPT = os.environ.get("BUNDLER_BUILD_SCRIPT", "/usr/local/bin/build.sh")
ALLOWED_IPS = [
    ip.strip()
    for ip in os.environ.get("BUNDLER_ALLOWED_IPS", "*").split(",")
    if ip.strip()
]
MAX_CONCURRENT = max(1, int(os.environ.get("BUNDLER_MAX_CONCURRENT", "1")))

JOBS_DIR.mkdir(parents=True, exist_ok=True)


app = FastAPI(title="nes-bundler")
build_semaphore = asyncio.Semaphore(MAX_CONCURRENT)


class Status(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"


def is_allowed(client_ip: str | None) -> bool:
    if "*" in ALLOWED_IPS or not ALLOWED_IPS:
        return True
    return client_ip in ALLOWED_IPS


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
        with log_path.open("wb") as log:
            proc = await asyncio.create_subprocess_exec(
                BUILD_SCRIPT,
                str(job_dir),
                stdout=log,
                stderr=asyncio.subprocess.STDOUT,
            )
            rc = await proc.wait()
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
async def create_bundle(request: Request, config: UploadFile):
    client_ip = request.client.host if request.client else None
    if not is_allowed(client_ip):
        raise HTTPException(status_code=403, detail="forbidden")

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
    bundle = job_dir / "bundle.tar.gz"
    if not bundle.exists():
        raise HTTPException(404, "bundle not ready")
    return FileResponse(
        bundle,
        media_type="application/gzip",
        filename=f"nes-bundler-{job_id}.tar.gz",
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
