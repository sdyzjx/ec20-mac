#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOHIVE_DIR="$PROJECT_DIR/third_party/vohive"
GO_BIN=${GO_BIN:-go}
DARWIN_ARCH=${DARWIN_ARCH:-}
OUTPUT_PATH=${OUTPUT_PATH:-"$PROJECT_DIR/build/vohive-darwin/vohive"}
SKIP_FRONTEND=false

usage()
{
    cat <<'EOF'
Usage: tools/build-vohive-darwin.sh [--skip-frontend] [--arch arm64|amd64] [--output PATH]

Builds the pinned Vohive backend and embedded UI without Developer ID signing.
The linker may apply an ad-hoc signature; this is not a distributable macOS app.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        --arch)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            DARWIN_ARCH=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            OUTPUT_PATH=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$DARWIN_ARCH" ]; then
    case "$(uname -m)" in
        arm64) DARWIN_ARCH=arm64 ;;
        x86_64) DARWIN_ARCH=amd64 ;;
        *)
            echo "unsupported host architecture; pass --arch arm64 or --arch amd64" >&2
            exit 2
            ;;
    esac
fi
case "$DARWIN_ARCH" in
    arm64|amd64) ;;
    *)
        echo "unsupported Darwin architecture: $DARWIN_ARCH" >&2
        exit 64
        ;;
esac

command -v "$GO_BIN" >/dev/null 2>&1 || {
    echo "Go executable not found: $GO_BIN" >&2
    exit 2
}

if [ "$SKIP_FRONTEND" = false ]; then
    command -v npm >/dev/null 2>&1 || {
        echo "npm is required to rebuild the embedded Vohive UI" >&2
        exit 2
    }
    make -C "$VOHIVE_DIR" frontend-dist
elif [ ! -f "$VOHIVE_DIR/internal/web/dist/index.html" ]; then
    echo "--skip-frontend requires internal/web/dist/index.html" >&2
    exit 2
fi

mkdir -p "$(dirname -- "$OUTPUT_PATH")"
VERSION=$(git -C "$PROJECT_DIR" describe --tags --always --dirty)
BUILD_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LDFLAGS="-s -w -X github.com/1239t/vohive/internal/global.Version=$VERSION -X github.com/1239t/vohive/internal/global.BuildTime=$BUILD_TIME"

(
    cd "$VOHIVE_DIR"
    GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH="$DARWIN_ARCH" \
        "$GO_BIN" build \
        -trimpath \
        -buildvcs=false \
        -tags "with_utls nomsgpack" \
        -ldflags "$LDFLAGS" \
        -o "$OUTPUT_PATH" \
        ./cmd/vohive
)

echo "built Darwin Vohive bring-up binary (no Developer ID signing): $OUTPUT_PATH"
