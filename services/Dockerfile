# One Dockerfile for all 7 containerised Python services (+ a "test" stage).
# Build from the REPO ROOT:
#   docker build -f services/Dockerfile --build-arg SERVICE=incident-intake -t incident-intake:dev .
#   docker build -f services/Dockerfile --target test .        # runs the Dynamo test-suite (no Python on the host needed)
# The dependency layer is identical for every service, so Artifact Registry stores it once.
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /srv
COPY services/requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

# gRPC stubs are generated at build time from the single source of truth (proto/)
COPY proto /src/proto
COPY services/common /src/services/common
COPY scripts/gen_proto.py /src/scripts/gen_proto.py
RUN python /src/scripts/gen_proto.py /src && cp -r /src/services/common /srv/common

# ---------------------------------------------------------------- test stage (optional target)
FROM base AS test
RUN pip install pytest==9.2.0
COPY services /src/services
COPY tests /src/tests
COPY scripts/gen_proto.py /src/scripts/gen_proto.py
WORKDIR /src
RUN python /src/scripts/gen_proto.py /src && python -m pytest -q -p no:cacheprovider tests/

# ---------------------------------------------------------------- runtime stage (default)
FROM base AS runtime
ARG SERVICE
RUN test -n "$SERVICE" || (echo "--build-arg SERVICE=<name> is required" && exit 1)
ENV SERVICE=${SERVICE} PYTHONPATH=/srv/common:/srv
COPY services/${SERVICE}/app /srv/app

RUN useradd --uid 10001 --create-home app && mkdir -p /data && chown app /data
USER 10001
EXPOSE 8080 50051
CMD ["sh", "-c", "if [ \"$SERVICE\" = incident-store ]; then exec python -m app.server; else exec uvicorn app.main:app --host 0.0.0.0 --port 8080 --no-access-log --timeout-graceful-shutdown 10; fi"]
