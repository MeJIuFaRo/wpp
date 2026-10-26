#!/usr/bin/env bash
# Build, check and publish the images. The build host has 1 GB RAM, so images
# are built one at a time.
#   scripts/build.sh build [image...]   build all or the listed images
#   scripts/build.sh test               run tests against the built images
#   scripts/build.sh scan               check images for production data
#   scripts/build.sh push [tag]         scan, then push $WPP_VERSION (or tag)
#   scripts/build.sh release            push $WPP_VERSION and latest
#   scripts/build.sh clean              drop the build cache
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a; . ./versions.env; set +a

IMAGES=(relay mtproxy xray openflux panel)
NS="$DOCKERHUB_NAMESPACE"
TAG="${TAG:-$WPP_VERSION}"
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

build_one() {
    local name="$1"
    [[ -f "images/$name/Dockerfile" ]] || { echo "no images/$name/Dockerfile" >&2; return 1; }
    docker buildx build --load --progress=plain \
        --build-arg GO_IMAGE="$GO_IMAGE" --build-arg PYTHON_IMAGE="$PYTHON_IMAGE" \
        --build-arg TPROXY_REPO="$TPROXY_REPO" --build-arg TPROXY_REF="$TPROXY_REF" \
        --build-arg MTPROXY_COMMIT="$MTPROXY_COMMIT" --build-arg MTPROXY_SHA256="$MTPROXY_SHA256" \
        --build-arg XRAY_VERSION="$XRAY_VERSION" --build-arg XRAY_SHA256="$XRAY_SHA256" \
        --build-arg OPENFLUX_REPO="$OPENFLUX_REPO" \
        --build-arg OPENFLUX_VERSION="$OPENFLUX_VERSION" --build-arg OPENFLUX_SHA256="$OPENFLUX_SHA256" \
        --build-arg WPP_VERSION="$TAG" --build-arg CADDY_IMAGE="$CADDY_IMAGE" \
        --build-arg RELAY_IMAGE="$NS/wpp-relay:$TAG" --build-arg XRAY_IMAGE="$NS/wpp-xray:$TAG" \
        --build-arg OPENFLUX_IMAGE="$NS/wpp-openflux:$TAG" \
        --label org.opencontainers.image.version="$TAG" \
        --label org.opencontainers.image.revision="$REVISION" \
        -f "images/$name/Dockerfile" -t "$NS/wpp-$name:$TAG" .
}

scan_all() { for i in "${IMAGES[@]}"; do scripts/scan-image.sh "$NS/wpp-$i:$TAG"; done; }
push_tag() { for i in "${IMAGES[@]}"; do docker tag "$NS/wpp-$i:$TAG" "$NS/wpp-$i:$1"; docker push "$NS/wpp-$i:$1"; done; }

cmd="${1:-build}"; shift || true
case "$cmd" in
    build)
        scripts/fetch-upstream.sh
        [[ $# -gt 0 ]] || set -- "${IMAGES[@]}"
        for i in "$@"; do build_one "$i"; done ;;
    test)    tests/run.sh "$NS" "$TAG" ;;
    scan)    scan_all ;;
    push)    scan_all; push_tag "${1:-$TAG}" ;;
    release) scan_all; push_tag "$TAG"; push_tag latest ;;
    clean)   docker builder prune -f ;;
    *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
