# syntax=docker/dockerfile:1
# The starter is part of the Daravel pub workspace, so build it from the
# repository root:
#   docker build -f apps/daravel_starter/Dockerfile -t daravel-starter .
# Projects created with `dartisan new` get a standalone Dockerfile with the
# same runtime stage.
FROM dart:stable AS build
WORKDIR /repo
COPY . .
RUN dart pub get \
 && cd apps/daravel_starter \
 && dart build cli -t bin/server.dart -o build/server \
 && dart build cli -t bin/dartisan.dart -o build/dartisan \
 && mkdir -p /app \
 && cp -r build /app/build

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home /app daravel
WORKDIR /app
# bin/server and bin/dartisan share the bundled lib/ (SQLite).
COPY --from=build /app/build/server/bundle/ ./
COPY --from=build /app/build/dartisan/bundle/bin/dartisan ./bin/dartisan
RUN mkdir -p storage/logs storage/app database && chown -R daravel /app
USER daravel
# PORT (not APP_PORT) so Cloud Run, Railway, Render and Fly.io can inject theirs.
ENV APP_ENV=production APP_DEBUG=false APP_HOST=0.0.0.0 PORT=8080 \
    LOG_STACK=json
EXPOSE 8080
# Health: GET /up (liveness) and /up/ready (readiness).
CMD ["/app/bin/server"]
