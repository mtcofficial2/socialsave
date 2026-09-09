from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Optional


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


class JobStore:
    def __init__(self) -> None:
        self._jobs: dict[str, DownloadJob] = {}

    def create(self) -> DownloadJob:
        job = DownloadJob(id=uuid.uuid4().hex)
        self._jobs[job.id] = job
        return job

    def get(self, job_id: str) -> Optional[DownloadJob]:
        return self._jobs.get(job_id)


job_store = JobStore()
