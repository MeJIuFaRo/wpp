# OpenFlux exit node, pinned release with checksum. Units are written by the panel.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM debian:bookworm-slim AS fetch
ARG OPENFLUX_VERSION
ARG OPENFLUX_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
# downloads/ is an optional local cache (the build host is slow to reach GitHub).
COPY downloads/ /downloads/
RUN f="/downloads/openflux-linux-amd64-${OPENFLUX_VERSION}"; \
    [ -s "$f" ] || curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$f" \
        "https://github.com/damnurmum/OpenFlux-Android/releases/download/v${OPENFLUX_VERSION}/openflux-linux-amd64"; \
    echo "${OPENFLUX_SHA256}  $f" | sha256sum -c - && install -m 0755 "$f" /out-openflux

FROM ${PYTHON_IMAGE}
RUN groupadd -g 10000 wpp && useradd -u 10000 -g wpp -M -d /var/lib/wpp-openflux -s /usr/sbin/nologin wpp
COPY --from=fetch /out-openflux /opt/web-panel-proxy/openflux/openflux
COPY src/agent/wpp_agent.py /usr/local/lib/wpp/wpp_agent.py
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/var/lib/wpp-openflux \
    WPP_AGENT_NAME=openflux WPP_AGENT_PORT=9105 \
    WPP_AGENT_UNITS="web-panel-proxy-openflux.service web-panel-proxy-openflux-*.service"
USER 10000:10000
ENTRYPOINT ["python3", "/usr/local/lib/wpp/wpp_agent.py"]
