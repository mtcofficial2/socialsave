"""Optional object-storage delivery.

When configured later (S3/R2/etc.), prepared files can be uploaded and Flutter
can download a short-lived signed URL instead of streaming through Render.

Unconfigured, this is a no-op so current deploys keep working.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Protocol

from app.config import Settings


class ObjectStore(Protocol):
    def enabled(self) -> bool: ...

    def put_file(self, path: Path, name: str) -> Optional[str]:
        """Return a public/signed HTTPS URL, or None if upload is unavailable."""


class NoObjectStore:
    def enabled(self) -> bool:
        return False

    def put_file(self, path: Path, name: str) -> Optional[str]:
        return None


def get_object_store(settings: Settings) -> ObjectStore:
    # Wire S3/R2 here when OBJECT_STORAGE_URL and credentials are set.
    if (settings.object_storage_url or "").strip():
        return NoObjectStore()
    return NoObjectStore()
