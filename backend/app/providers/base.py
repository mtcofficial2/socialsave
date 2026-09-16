from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional

from app.models import MediaFormat


@dataclass
class MediaMetadata:
    platform: str
    title: str
    source_url: str
    thumbnail: Optional[str] = None
    duration: Optional[int] = None
    author: Optional[str] = None
    formats: list[MediaFormat] = field(default_factory=list)
    can_download: bool = False
    download_restricted_reason: Optional[str] = None


@dataclass
class DownloadHandle:
    source_url: str
    format_id: str
    mime_type: Optional[str] = None
    filesize: Optional[int] = None
    file_name: Optional[str] = None
    upstream_url: Optional[str] = None
    prepare_locally: bool = False
    http_headers: Optional[dict[str, str]] = None


class SocialMediaProvider(ABC):
    """Server-side provider. Flutter never talks to social platforms directly."""

    id: str
    display_name: str
    supports_metadata: bool = True
    supports_download: bool = False
    notes: str = ""

    @abstractmethod
    def can_handle(self, url: str) -> bool:
        raise NotImplementedError

    @abstractmethod
    async def analyze(self, url: str) -> MediaMetadata:
        raise NotImplementedError

    async def create_download(self, url: str, format_id: str) -> DownloadHandle:
        raise NotImplementedError
