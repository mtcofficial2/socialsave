from typing import Any, Optional

from pydantic import BaseModel, Field, HttpUrl


class AnalyzeRequest(BaseModel):
    url: str = Field(min_length=8, max_length=2048)


class DownloadRequest(BaseModel):
    url: str = Field(min_length=8, max_length=2048)
    format_id: str = Field(min_length=1, max_length=64)


class MediaFormat(BaseModel):
    id: str
    quality: str
    format: str
    filesize: Optional[int] = None
    width: Optional[int] = None
    height: Optional[int] = None
    has_audio: bool = True
    has_video: bool = True


class AnalyzeResponse(BaseModel):
    success: bool = True
    platform: str
    title: str
    thumbnail: Optional[str] = None
    duration: Optional[int] = None
    author: Optional[str] = None
    url: str
    formats: list[MediaFormat] = Field(default_factory=list)
    can_download: bool = False
    download_restricted_reason: Optional[str] = None


class DownloadResponse(BaseModel):
    success: bool = True
    download_url: str = ""
    id: Optional[str] = None
    state: str = "ready"
    expires_at: Optional[str] = None
    mime_type: Optional[str] = None
    filesize: Optional[int] = None
    file_name: Optional[str] = None


class PlatformStatus(BaseModel):
    id: str
    enabled: bool
    supports_metadata: bool
    supports_download: bool
    notes: Optional[str] = None


class PlatformsResponse(BaseModel):
    success: bool = True
    platforms: list[PlatformStatus]


class JobStatusResponse(BaseModel):
    success: bool = True
    id: str
    state: str
    download_url: Optional[str] = None
    error: Optional[dict[str, Any]] = None
    progress: Optional[float] = None
    filesize: Optional[int] = None
    file_name: Optional[str] = None
