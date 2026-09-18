from fastapi import HTTPException, status


class ApiError(HTTPException):
    def __init__(self, code: str, message: str, status_code: int = 400) -> None:
        super().__init__(
            status_code=status_code,
            detail={"success": False, "error": {"code": code, "message": message}},
        )
        self.code = code
        self.message = message


def invalid_url(message: str = "That URL cannot be used.") -> ApiError:
    return ApiError("invalid_url", message, status.HTTP_400_BAD_REQUEST)


def unsupported_platform() -> ApiError:
    return ApiError(
        "unsupported_platform",
        "This platform is not supported, or it has been disabled.",
        status.HTTP_400_BAD_REQUEST,
    )


def platform_disabled() -> ApiError:
    return ApiError(
        "platform_disabled",
        "This platform is turned off in the current configuration.",
        status.HTTP_403_FORBIDDEN,
    )


def private_video(message: str | None = None) -> ApiError:
    return ApiError(
        "private_video",
        message
        or "Unable to access this video. Make sure the link is public and that downloading is permitted for this content.",
        status.HTTP_403_FORBIDDEN,
    )


def removed_video() -> ApiError:
    return ApiError("removed_video", "This video is no longer available.", status.HTTP_404_NOT_FOUND)


def download_not_permitted() -> ApiError:
    return ApiError(
        "download_not_permitted",
        "This platform does not allow third-party apps to download the file. SocialSave will not bypass that restriction.",
        status.HTTP_403_FORBIDDEN,
    )


def unsupported_format() -> ApiError:
    return ApiError(
        "unsupported_format",
        "This file type is not a supported video format.",
        status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
    )


def file_too_large(max_bytes: int | None = None) -> ApiError:
    limit = max_bytes or 104_857_600
    megabytes = max(1, limit // (1024 * 1024))
    return ApiError(
        "file_too_large",
        f"This file is larger than the {megabytes} MB download limit.",
        status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
    )


def unauthorized() -> ApiError:
    return ApiError("unauthorized", "Missing or invalid API key.", status.HTTP_401_UNAUTHORIZED)


def platform_unavailable(message: str | None = None) -> ApiError:
    return ApiError(
        "platform_unavailable",
        message
        or "The source platform is temporarily unavailable. Try again later.",
        status.HTTP_503_SERVICE_UNAVAILABLE,
    )
