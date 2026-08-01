#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
VOHIVE_BIN=${VOHIVE_BIN:-"$PROJECT_DIR/build/vohive-darwin/vohive"}
CONFIG_PATH=""
LISTEN_PORT=17575
LOCATION_ID=""
RUNTIME_DIR=""
EC20D_PID=""
VOHIVE_PID=""

usage()
{
    cat <<'EOF'
Usage: tools/run-vohive-darwin.sh --config PATH [--port PORT] [--location-id ID]

Starts ec20d and the Vohive Darwin backend for direct browser access. The Web API is
forced to 127.0.0.1; dynamic PTY and enX paths remain runtime-only.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            CONFIG_PATH=$2
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            LISTEN_PORT=$2
            shift 2
            ;;
        --location-id)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            LOCATION_ID=$2
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

[ -n "$CONFIG_PATH" ] || { echo "--config is required" >&2; exit 64; }
case "$LISTEN_PORT" in
    ''|*[!0-9]*) echo "invalid port: $LISTEN_PORT" >&2; exit 64 ;;
esac
[ "$LISTEN_PORT" -ge 1024 ] && [ "$LISTEN_PORT" -le 65535 ] || {
    echo "port must be between 1024 and 65535" >&2
    exit 64
}

CONFIG_DIR=$(CDPATH= cd -- "$(dirname -- "$CONFIG_PATH")" && pwd)
CONFIG_PATH="$CONFIG_DIR/$(basename -- "$CONFIG_PATH")"
[ -f "$CONFIG_PATH" ] || { echo "config file not found: $CONFIG_PATH" >&2; exit 2; }
[ ! -L "$CONFIG_PATH" ] || { echo "config must not be a symlink: $CONFIG_PATH" >&2; exit 2; }
[ -x "$EC20D_BIN" ] || { echo "ec20d binary not found: $EC20D_BIN" >&2; exit 2; }
[ -x "$VOHIVE_BIN" ] || { echo "Vohive binary not found: $VOHIVE_BIN" >&2; exit 2; }

if grep -q 'CHANGE_ME_BEFORE_START' "$CONFIG_PATH"; then
    echo "replace CHANGE_ME_BEFORE_START with a strong local password" >&2
    exit 2
fi
if lsof -nP -iTCP:"$LISTEN_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $LISTEN_PORT is already in use" >&2
    exit 2
fi

cleanup()
{
    trap - INT TERM EXIT
    if [ -n "$VOHIVE_PID" ] && kill -0 "$VOHIVE_PID" 2>/dev/null; then
        kill "$VOHIVE_PID" 2>/dev/null || true
        wait "$VOHIVE_PID" 2>/dev/null || true
    fi
    if [ -n "$EC20D_PID" ] && kill -0 "$EC20D_PID" 2>/dev/null; then
        kill "$EC20D_PID" 2>/dev/null || true
        wait "$EC20D_PID" 2>/dev/null || true
    fi
    if [ -n "$RUNTIME_DIR" ]; then
        [ ! -S "$RUNTIME_DIR/ec20d.sock" ] || unlink "$RUNTIME_DIR/ec20d.sock"
        rmdir "$RUNTIME_DIR" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ec20-vohive-darwin.XXXXXX")
chmod 0700 "$RUNTIME_DIR"
SOCKET_PATH="$RUNTIME_DIR/ec20d.sock"

set -- --pty --allow-arbitrary-at --socket "$SOCKET_PATH"
if [ -n "$LOCATION_ID" ]; then
    set -- "$@" --pty-location-id "$LOCATION_ID"
fi
"$EC20D_BIN" "$@" &
EC20D_PID=$!

ec20_socket_attempt=0
while [ "$ec20_socket_attempt" -lt 100 ]; do
    [ -S "$SOCKET_PATH" ] && break
    kill -0 "$EC20D_PID" 2>/dev/null || {
        echo "ec20d exited before publishing its socket" >&2
        exit 1
    }
    ec20_socket_attempt=$((ec20_socket_attempt + 1))
    sleep 0.1
done
[ -S "$SOCKET_PATH" ] || { echo "timed out waiting for ec20d socket" >&2; exit 1; }

(
    cd "$PROJECT_DIR/third_party/vohive"
    exec env \
        EC20D_SOCKET="$SOCKET_PATH" \
        PROXY_SERVER_HOST=127.0.0.1 \
        PROXY_SERVER_PORT="$LISTEN_PORT" \
        "$VOHIVE_BIN" -c "$CONFIG_PATH"
) &
VOHIVE_PID=$!

ec20_http_attempt=0
while [ "$ec20_http_attempt" -lt 300 ]; do
    if curl --noproxy '*' -fsS -o /dev/null --connect-timeout 1 "http://127.0.0.1:$LISTEN_PORT/" 2>/dev/null; then
        echo "Vohive Web is ready: http://127.0.0.1:$LISTEN_PORT/"
        break
    fi
    kill -0 "$VOHIVE_PID" 2>/dev/null || {
        echo "Vohive exited before the Web service became ready" >&2
        exit 1
    }
    ec20_http_attempt=$((ec20_http_attempt + 1))
    sleep 0.1
done
[ "$ec20_http_attempt" -lt 300 ] || { echo "timed out waiting for Vohive Web" >&2; exit 1; }

while kill -0 "$EC20D_PID" 2>/dev/null && kill -0 "$VOHIVE_PID" 2>/dev/null; do
    sleep 1
done
echo "a managed service exited; stopping the remaining process" >&2
exit 1
