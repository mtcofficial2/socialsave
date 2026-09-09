from fastapi import APIRouter, Depends

from app.auth import require_api_key
from app.config import Settings, get_settings
from app.models import AnalyzeRequest, AnalyzeResponse
from app.providers.registry import ProviderRegistry
from app.security import validate_public_url

router = APIRouter(dependencies=[Depends(require_api_key)])


@router.post("/api/v1/analyze", response_model=AnalyzeResponse)
async def analyze(
    payload: AnalyzeRequest,
    settings: Settings = Depends(get_settings),
) -> AnalyzeResponse:
    url = validate_public_url(payload.url)
    provider = ProviderRegistry(settings).resolve(url)
    result = await provider.analyze(url)
    return AnalyzeResponse(
        platform=result.platform,
        title=result.title,
        thumbnail=result.thumbnail,
        duration=result.duration,
        author=result.author,
        url=result.source_url,
        formats=result.formats,
        can_download=result.can_download,
        download_restricted_reason=result.download_restricted_reason,
    )
