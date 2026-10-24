# Official MTProxy from the pinned commit plus src/mtproxy-patches (64 keys,
# exact client byte counters). One image, two roles selected by environment:
#   backends (default): primary WEB backend mtproxy.service + web-proxy-user-*.service
#   mtproto:            shared MTProto listener web-panel-proxy-mtproto.service on 8443
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM debian:bookworm-slim AS build
ARG MTPROXY_COMMIT
ARG MTPROXY_SHA256
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates curl libssl-dev zlib1g-dev patch \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/mtproxy.tar.gz \
        "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
 && echo "${MTPROXY_SHA256}  /tmp/mtproxy.tar.gz" | sha256sum -c - \
 && tar --strip-components=1 -xzf /tmp/mtproxy.tar.gz && rm /tmp/mtproxy.tar.gz
COPY src/mtproxy-patches/ /patches/
RUN for p in /patches/*.patch; do patch -s -p1 < "$p" || exit 1; done
# The build host has 1 GB RAM.
RUN make -j2 COMMIT="${MTPROXY_COMMIT}-wpp" && test -x objs/bin/mtproto-proxy

FROM ${PYTHON_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 zlib1g iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 10000 wpp && useradd -u 10000 -g wpp -M -d /nonexistent -s /usr/sbin/nologin wpp
# Same paths as on a VPS: the panel writes units with these ExecStart lines.
# The path itself is a wrapper that adds --nat-info for Docker NAT.
COPY --from=build /src/objs/bin/mtproto-proxy /opt/MTProxy/objs/bin/mtproto-proxy.real
COPY images/mtproxy/mtproto-proxy-wrapper /opt/MTProxy/objs/bin/mtproto-proxy
RUN chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy \
 && install -d /opt/web-panel-proxy/mtproto-shared \
 && ln -s /opt/MTProxy/objs/bin/mtproto-proxy /opt/web-panel-proxy/mtproto-shared/mtproto-proxy
COPY src/agent/wpp_agent.py /usr/local/lib/wpp/wpp_agent.py
COPY images/mtproxy/units/ /etc/wpp-agent/units/
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    WPP_AGENT_NAME=backends WPP_AGENT_PORT=9102 \
    WPP_AGENT_UNITS="mtproxy.service web-proxy-user-*.service"
USER 10000:10000
ENTRYPOINT ["python3", "/usr/local/lib/wpp/wpp_agent.py"]
