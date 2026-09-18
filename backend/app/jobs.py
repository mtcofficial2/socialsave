from __future__ import annotations

import logging
import shutil
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger("socialsave.jobs")


def delete_media_path(path: Optional[str]) -> None:
    if not path:
        return
    target = Path(path)
    try:
        if target.is_file():
            target.unlink()
        parent = target.parent
        if parent.is_dir() and parent.name.startswith("socialsave-"):
            shutil.rmtree(parent, ignore_errors=True)
        logger.info("cleanup success path_kind=temp")
    except OSError:
        logger.warning("cleanup failed path_kind=temp")


@dataclass
class DownloadJob:
    id: str
    state: str = "processing"
    progress: float = 0.0
    file_path: Optional[str] = None
    mime_type: str = "video/mp4"
    file_name: str = "video.mp4"
    filesize: Optional[int] = None
    download_url: Optional[str] = None
    error: Optional[dict[str, str]] = None
    created_at: float = field(default_factory=time.time)
    ready_at: Optional[float] = None


class JobStore:
    def __init__(self, ttl_seconds: int = 600) -> None:
        self._jobs: dict[str, DownloadJob] = {}
        self._ttl = ttl_seconds
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def configure(self, ttl_seconds: int) -> None:
        self._ttl = max(60, ttl_seconds)

    def start_reaper(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="job-reaper", daemon=True)
        self._thread.start()

    def stop_reaper(self) -> None:
        self._stop.set()

    def create(self) -> DownloadJob:
        self.purge()
        job = DownloadJob(id=uuid.uuid4().hex)
        with self._lock:
            self._jobs[job.id] = job
        return job

    def get(self, job_id: str) -> Optional[DownloadJob]:
        self.purge()
        with self._lock:
            return self._jobs.get(job_id)

    def pop(self, job_id: str) -> Optional[DownloadJob]:
        with self._lock:
            return self._jobs.pop(job_id, None)

    def mark_ready(self, job: DownloadJob) -> None:
        job.state = "ready"
        job.progress = 1
        job.ready_at = time.time()

    def purge(self) -> None:
        now = time.time()
        expired: list[str] = []
        with self._lock:
            for job_id, job in self._jobs.items():
                if job.state == "processing":
                    limit = max(self._ttl, 900)
                    if now - job.created_at > limit:
                        expired.append(job_id)
                elif job.state == "failed":
                    if now - job.created_at > 300:
                        expired.append(job_id)
                else:
                    start = job.ready_at or job.created_at
                    if now - start > self._ttl:
                        expired.append(job_id)
            removed = [self._jobs.pop(job_id) for job_id in expired]
        for job in removed:
            delete_media_path(job.file_path)

    def _loop(self) -> None:
        while not self._stop.wait(30):
            try:
                self.purge()
            except Exception:
                logger.warning("job reaper failed")


job_store = JobStore()
