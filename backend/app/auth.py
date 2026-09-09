from fastapi import Depends, Header

from app.config import Settings, get_settings
from app.errors import unauthorized


async def require_api_key(
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> None:
    if not settings.require_api_key:
        return
    token = x_api_key
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization.split(" ", 1)[1]
    if not token or token not in settings.api_key_set:
        raise unauthorized()
