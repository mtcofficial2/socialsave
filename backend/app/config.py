from functools import lru_cache
from typing import FrozenSet

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "SocialSave API"
    environment: str = "development"
    secret_key: str = "change-me-in-production"
    public_base_url: str = "http://127.0.0.1:8000"
    require_api_key: bool = False
    api_keys: str = ""

    enabled_platforms: str = (
        "tiktok,instagram,facebook,x,youtube,reddit,pinterest,direct"
    )
    max_download_bytes: int = 2_147_483_647
    default_max_height: int = 1080
    token_ttl_seconds: int = 3600
    job_ttl_seconds: int = 600
    request_timeout_seconds: float = 30.0
    max_redirects: int = 3
    analyze_rate_limit: str = "30/minute"
    download_rate_limit: str = "10/minute"
    object_storage_url: str = ""

    youtube_api_key: str = ""
    instagram_access_token: str = ""
    facebook_access_token: str = ""
    x_bearer_token: str = ""

    @property
    def enabled_platform_set(self) -> FrozenSet[str]:
        return frozenset(
            item.strip().lower()
            for item in self.enabled_platforms.split(",")
            if item.strip()
        )

    @property
    def api_key_set(self) -> FrozenSet[str]:
        return frozenset(
            item.strip() for item in self.api_keys.split(",") if item.strip()
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
