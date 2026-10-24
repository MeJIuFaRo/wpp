# Panel, manager and periodic jobs. Built after the service images: it takes
# their binaries for the checks the panel runs itself (tproxy-server -check,
# xray run -test, caddy validate, OpenFlux presence).
ARG PYTHON_IMAGE=python:3.12-slim-bookworm
ARG CADDY_IMAGE=caddy:2.11.4
ARG RELAY_IMAGE
ARG XRAY_IMAGE
ARG OPENFLUX_IMAGE

FROM ${RELAY_IMAGE} AS relay
FROM ${XRAY_IMAGE} AS xray
FROM ${OPENFLUX_IMAGE} AS openflux
FROM ${CADDY_IMAGE} AS caddy

FROM ${PYTHON_IMAGE}
ARG WPP_VERSION=unknown
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl qrencode iproute2 util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 10000 wpp && useradd -u 10000 -g wpp -M -d /nonexistent -s /usr/sbin/nologin wpp \
 # The panel refers to the VPS service accounts by name; in the containers
 # they are all the same unprivileged account (UID/GID 10000).
 && for name in tproxy xray caddy mtproxy wpp-openflux; do \
        groupadd -o -g 10000 "$name" && useradd -o -u 10000 -g 10000 -M -d "/var/lib/$name" -s /usr/sbin/nologin "$name"; \
    done \
 && install -d -m 1777 /run/lock
COPY --from=relay /usr/local/bin/tproxy-server /usr/local/bin/tproxy-server
COPY --from=xray /opt/web-panel-proxy/xray/xray /opt/web-panel-proxy/xray/xray
COPY --from=openflux /opt/web-panel-proxy/openflux/openflux /opt/web-panel-proxy/openflux/openflux
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY src/panel/*.py /opt/tproxy-panel/
COPY upstream/web-panel-proxy/panel-logo.png /opt/tproxy-panel/panel-logo.png
COPY src/panel/web-proxy-panelctl src/panel/bin/wpp-init src/panel/bin/wpp-panel-start src/panel/bin/wpp-panel-entrypoint \
     src/panel/bin/web-panel-proxy-sync-tls src/panel/bin/refresh-mtproxy-config /usr/local/sbin/
COPY src/panel/bin/wpp-systemctl /usr/local/bin/systemctl
COPY src/panel/share/ /usr/local/share/wpp/
COPY src/agent/wpp_agent.py /usr/local/lib/wpp/wpp_agent.py
COPY images/panel/units/ /etc/wpp-agent/units/
# The official caddy binary carries a file capability (cap_net_bind_service);
# without capabilities it would fail to exec. The panel only validates configs.
RUN cp /usr/bin/caddy /tmp/caddy && mv /tmp/caddy /usr/bin/caddy \
 && ln -s systemctl /usr/local/bin/journalctl \
 && chmod 0755 /usr/local/sbin/* /usr/local/bin/systemctl \
 && python3 -m py_compile /opt/tproxy-panel/*.py /usr/local/lib/wpp/wpp_agent.py \
 && python3 -c "import ast,sys; [ast.parse(open(f).read(),f) for f in sys.argv[1:]]" \
        /usr/local/sbin/web-proxy-panelctl /usr/local/sbin/wpp-init /usr/local/bin/systemctl \
 && rm -rf /opt/tproxy-panel/__pycache__ /usr/local/lib/wpp/__pycache__
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 WPP_DOCKER=1 WPP_VERSION=${WPP_VERSION} \
    WPP_AGENT_NAME=panel WPP_AGENT_PORT=9100 \
    WPP_AGENT_UNITS="tproxy-panel.service web-proxy-panel-traffic.service web-panel-proxy-metrics.service web-panel-proxy-sync-tls.service refresh-mtproxy-config.service"
USER 10000:10000
ENTRYPOINT ["/usr/local/sbin/wpp-panel-entrypoint"]
