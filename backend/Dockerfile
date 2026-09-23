FROM golang:1.27-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip ffmpeg \
    && curl -fsSL -o /usr/local/bin/yt-dlp \
        https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_linux \
    && chmod 755 /usr/local/bin/yt-dlp \
    && curl -fsSL -o /tmp/deno.zip \
        https://github.com/denoland/deno/releases/download/v2.9.7/deno-x86_64-unknown-linux-gnu.zip \
    && unzip -j /tmp/deno.zip deno -d /usr/local/bin \
    && chmod 755 /usr/local/bin/deno \
    && rm /tmp/deno.zip \
    && apt-get purge -y curl unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/api /usr/local/bin/api

ENV PORT=8080 \
    HOME=/tmp \
    YTDLP_NO_UPDATE=1
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/api"]
