# Xray (VLESS XHTTP behind Caddy, Hysteria2 on UDP 8443), pinned release with checksum.
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM debian:bookworm-slim AS fetch
ARG XRAY_VERSION
ARG XRAY_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
# downloads/ is an optional local cache (the build host is slow to reach GitHub).
COPY downloads/ /downloads/
RUN f="/downloads/Xray-linux-64-${XRAY_VERSION}.zip"; \
    [ -s "$f" ] || curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$f" \
        "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"; \
    echo "${XRAY_SHA256}  $f" | sha256sum -c - \
 && unzip -q "$f" xray -d /out && chmod 0755 /out/xray

FROM ${PYTHON_IMAGE}
RUN groupadd -g 10000 wpp && useradd -u 10000 -g wpp -M -d /nonexistent -s /usr/sbin/nologin wpp
COPY --from=fetch /out/xray /opt/web-panel-proxy/xray/xray
COPY src/agent/wpp_agent.py /usr/local/lib/wpp/wpp_agent.py
COPY images/xray/units/ /etc/wpp-agent/units/
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    WPP_AGENT_NAME=xray WPP_AGENT_PORT=9104 WPP_AGENT_UNITS="web-panel-proxy-xray.service"
USER 10000:10000
ENTRYPOINT ["python3", "/usr/local/lib/wpp/wpp_agent.py"]
