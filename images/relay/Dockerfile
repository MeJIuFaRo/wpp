# WEB relay (tproxy-server) built from the pinned upstream commit plus src/relay-patches.
ARG GO_IMAGE=golang:1.26.5-bookworm
ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM ${GO_IMAGE} AS source
ARG TPROXY_REPO
ARG TPROXY_REF
WORKDIR /src
RUN git init -q . \
 && git remote add origin "$TPROXY_REPO" \
 && git fetch -q --depth 1 origin "$TPROXY_REF" \
 && git -c advice.detachedHead=false checkout -q --detach FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$TPROXY_REF"
COPY src/relay-patches/ /patches/
RUN for p in /patches/*.patch; do git apply --whitespace=nowarn "$p" || exit 1; done
RUN go mod download

FROM source AS build
# The build host has 1 GB RAM: limit parallel compilation.
ENV CGO_ENABLED=0 GOFLAGS=-p=2
RUN go vet ./... && go test -count=1 ./...
RUN go build -trimpath -ldflags='-s -w' -o /out/tproxy-server ./cmd/tproxy-server

# Optional: docker buildx build --target race-test -f images/relay/Dockerfile .
FROM source AS race-test
ENV CGO_ENABLED=1 GOFLAGS=-p=1
RUN go test -race -count=1 ./...

FROM ${PYTHON_IMAGE}
RUN groupadd -g 10000 wpp && useradd -u 10000 -g wpp -M -d /nonexistent -s /usr/sbin/nologin wpp
COPY --from=build /out/tproxy-server /usr/local/bin/tproxy-server
COPY src/agent/wpp_agent.py /usr/local/lib/wpp/wpp_agent.py
COPY images/relay/units/ /etc/wpp-agent/units/
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    WPP_AGENT_NAME=relay WPP_AGENT_PORT=9101 WPP_AGENT_UNITS="tproxy-server.service"
USER 10000:10000
ENTRYPOINT ["python3", "/usr/local/lib/wpp/wpp_agent.py"]
