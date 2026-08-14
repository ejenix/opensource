# Multi-stage build for the control plane. Stage 1 resolves the pub workspace
# and AOT-compiles the server to a self-contained native executable; stage 2 is
# a `scratch` image carrying only the Dart runtime and that binary.
FROM dart:3.12 AS build

WORKDIR /app

# Copy the workspace manifests first so dependency resolution is cached across
# source-only changes. The lockfile is copied for a reproducible resolution.
COPY pubspec.yaml pubspec.lock ./
COPY packages/ ./packages/
RUN dart pub get --enforce-lockfile

# AOT-compile the control plane entry point to a native executable.
# `dart compile exe` does not create the output's parent directory — it fails
# with PathNotFoundException — so create it first.
RUN mkdir -p /app/bin && \
    dart compile exe packages/server/bin/ejenix_server.dart -o /app/bin/ejenix_server

# --- Runtime image: just the Dart runtime and the compiled binary. ---
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/ejenix_server /app/bin/ejenix_server

# Documented defaults; override via the environment (12-factor).
ENV EJENIX_PORT=8080 \
    EJENIX_DATA_DIR=/data
EXPOSE 8080

ENTRYPOINT ["/app/bin/ejenix_server"]
