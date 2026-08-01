#!/bin/sh

# Exercise the first Vohive Darwin DeviceProvider slice against ec20d.  The
# daemon is always in mock PTY mode, so this test cannot enumerate or write USB.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOHIVE_DIR=${VOHIVE_DIR:-"$PROJECT_DIR/third_party/vohive"}
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
GO_BIN=${GO_BIN:-go}

if [ ! -x "$EC20D_BIN" ]; then
    echo "missing executable: $EC20D_BIN" >&2
    exit 2
fi
if [ ! -f "$VOHIVE_DIR/go.mod" ] ||
   [ ! -f "$VOHIVE_DIR/cmd/vohive-darwin-probe/main.go" ]; then
    echo "incomplete Vohive Darwin provider tree: $VOHIVE_DIR" >&2
    exit 2
fi
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    echo "Go executable not found: $GO_BIN" >&2
    exit 2
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vohive-darwin-provider.XXXXXX") || exit 2
SOCKET_PATH="$TEST_TMPDIR/ec20d.sock"
DAEMON_LOG="$TEST_TMPDIR/ec20d.log"
DAEMON_PID=

cleanup()
{
    saved_status=$?
    trap - EXIT HUP INT TERM

    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi

    case "$TEST_TMPDIR" in
        "${TMPDIR:-/tmp}"/vohive-darwin-provider.*)
            rm -rf -- "$TEST_TMPDIR"
            ;;
        *)
            echo "refusing to remove unexpected temporary path: $TEST_TMPDIR" >&2
            ;;
    esac

    exit "$saved_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$EC20D_BIN" \
    --mock \
    --pty \
    --max-requests 4 \
    --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

attempt=0
while [ ! -S "$SOCKET_PATH" ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ec20d exited before creating the provider test socket" >&2
        sed -n '1,160p' "$DAEMON_LOG" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        echo "timed out waiting for ec20d provider test socket" >&2
        sed -n '1,160p' "$DAEMON_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

if provider_output=$(
    cd "$VOHIVE_DIR" &&
    GOWORK=off "$GO_BIN" run ./cmd/vohive-darwin-probe \
        --socket "$SOCKET_PATH" \
        --json
); then
    :
else
    provider_status=$?
    echo "Vohive Darwin provider exited with status $provider_status" >&2
    sed -n '1,160p' "$DAEMON_LOG" >&2
    exit 1
fi

case "$provider_output" in
    *'"instance_id": "usb-03120000-1"'*) ;;
    *)
        echo "provider output omitted the deterministic mock instance" >&2
        printf '%s\n' "$provider_output" >&2
        exit 1
        ;;
esac
case "$provider_output" in
    *'"path": "/dev/ttys'*) ;;
    *)
        echo "provider output omitted the PTY path" >&2
        printf '%s\n' "$provider_output" >&2
        exit 1
        ;;
esac
case "$provider_output" in
    *'"ownership": "cooperative_single_client"'*) ;;
    *)
        echo "provider output omitted the PTY ownership boundary" >&2
        printf '%s\n' "$provider_output" >&2
        exit 1
        ;;
esac
case "$provider_output" in
    *'"imei"'*|*'"firmware"'*)
        echo "provider diagnostic output exposed disallowed identity fields" >&2
        exit 1
        ;;
esac

PTY_PATH=$(printf '%s\n' "$provider_output" |
    sed -n 's@.*"path": "\(/dev/ttys[^"]*\)".*@\1@p')
if [ -z "$PTY_PATH" ]; then
    echo "could not recover the PTY path from provider output" >&2
    exit 1
fi

if pool_output=$(
    cd "$VOHIVE_DIR" &&
    GOWORK=off "$GO_BIN" run ./cmd/vohive-darwin-probe \
        --socket "$SOCKET_PATH" \
        --pool \
        --json
); then
    :
else
    pool_status=$?
    echo "Vohive Darwin Pool probe exited with status $pool_status" >&2
    sed -n '1,160p' "$DAEMON_LOG" >&2
    exit 1
fi

case "$pool_output" in
    *'"attachment_key": "ec20d:'*'"vendor_id_hex": "2c7c"'*'"product_id_hex": "0125"'*) ;;
    *)
        echo "Pool provider output omitted the EC20 attachment identity" >&2
        printf '%s\n' "$pool_output" >&2
        exit 1
        ;;
esac
case "$pool_output" in
    *'"driver_name": "ec20d-pty"'*'"path": "/dev/ttys'*'"mode": "at"'*'"network_capable": false'*) ;;
    *)
        echo "Pool provider output violated the AT-only capability mapping" >&2
        printf '%s\n' "$pool_output" >&2
        exit 1
        ;;
esac
case "$pool_output" in
    *'"imei"'*|*'"firmware"'*|*'"control_path"'*)
        echo "Pool provider diagnostic exposed disallowed fields" >&2
        exit 1
        ;;
esac

if wait "$DAEMON_PID"; then
    daemon_status=0
else
    daemon_status=$?
fi
DAEMON_PID=
if [ "$daemon_status" -ne 0 ]; then
    echo "ec20d returned status $daemon_status after the provider requests" >&2
    sed -n '1,160p' "$DAEMON_LOG" >&2
    exit 1
fi
if [ -e "$SOCKET_PATH" ] || [ -e "$PTY_PATH" ]; then
    echo "ec20d left provider test runtime endpoints behind" >&2
    exit 1
fi

echo "Vohive Darwin ec20d provider integration: PASS"
