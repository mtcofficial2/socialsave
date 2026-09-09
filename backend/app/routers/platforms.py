from fastapi import APIRouter, Depends

from app.auth import require_api_key
from app.config import Settings, get_settings
from app.models import PlatformStatus, PlatformsResponse
from app.providers.registry import ProviderRegistry

router = APIRouter(dependencies=[Depends(require_api_key)])


@router.get("/api/v1/platforms", response_model=PlatformsResponse)
async def platforms(settings: Settings = Depends(get_settings)) -> PlatformsResponse:
    registry = ProviderRegistry(settings)
    items = [
        PlatformStatus(
            id=provider.id,
            enabled=registry.is_enabled(provider),
            supports_metadata=provider.supports_metadata,
            supports_download=provider.supports_download and registry.is_enabled(provider),
            notes=provider.notes or None,
        )
        for provider in registry.all()
    ]
    return PlatformsResponse(platforms=items)
