# syntax=docker/dockerfile:1.7
# Sentinel sample service — hardened image (Month 2, DevSecOps)
#
#  * base image pinned by digest (a tag can be re-pointed; a digest cannot);
#    Dependabot proposes digest bumps as reviewed PRs
#  * dependencies installed with --require-hashes from a fully locked file:
#    a tampered or substituted wheel fails the build
#  * multi-stage: no pip, no build cache, no compiler in the runtime layer
#  * non-root numeric UID (Kubernetes runAsNonRoot can verify it), works with
#    a read-only root filesystem
ARG PYTHON_IMAGE=python:3.13-slim-trixie@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb

FROM ${PYTHON_IMAGE} AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --require-hashes --no-deps -r requirements.txt \
 && /opt/venv/bin/python -m pip uninstall -y pip

FROM ${PYTHON_IMAGE} AS runtime
ARG VERSION=0.2.0
ARG REVISION=unknown
LABEL org.opencontainers.image.title="sentinel-sample-service" \
      org.opencontainers.image.description="Sentinel health/metrics reference service" \
      org.opencontainers.image.source="https://github.com/yassirHam/sentinel-orion" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    PORT=8000 \
    SERVICE_VERSION=${VERSION}

# Upgrade OS packages present in the base (security fixes published after the
# digest was cut), then drop apt metadata. pip and the ensurepip wheels are
# removed: the app needs neither, and pip vendors its own urllib3/msgpack
# copies that scanners (rightly) report.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && (python -m pip uninstall -y pip setuptools wheel || true) \
 && rm -rf /usr/local/lib/python3.13/ensurepip \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /opt/venv /opt/venv
WORKDIR /srv
COPY --chown=root:root app ./app

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status==200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header", "--proxy-headers", "--forwarded-allow-ips", "127.0.0.1"]
