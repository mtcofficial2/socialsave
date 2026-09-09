FROM node:22-bookworm-slim AS nodebin
FROM denoland/deno:bin AS denobin
FROM mwader/static-ffmpeg:7.1 AS ffmpeg
FROM python:3.13-slim-bookworm

# yt-dlp EJS requires Node >= 22 (v20 is rejected). Deno is the default runtime.
COPY --from=nodebin /usr/local/bin/node /usr/local/bin/node
COPY --from=denobin /deno /usr/local/bin/deno
COPY --from=ffmpeg /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /ffprobe /usr/local/bin/ffprobe
RUN node -v && deno -V && ffmpeg -version && ffprobe -version

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --default-timeout=120 \
        "fastapi>=0.115.0" \
        "uvicorn>=0.32.0" \
        "httpx>=0.27.0" \
        "pydantic>=2.9.0" \
        "pydantic-settings>=2.6.0" \
        "python-dotenv>=1.0.1" \
        "yt-dlp[default]>=2026.8.19" \
        "yt-dlp-ejs" \
        "imageio-ffmpeg>=0.5.1" \
        "curl_cffi>=0.10,<0.16" \
    && python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())"

COPY app ./app
COPY static ./static

ENV ENVIRONMENT=production
ENV PYTHONUNBUFFERED=1
ENV REQUIRE_API_KEY=false
ENV PORT=8000
EXPOSE 8000

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
