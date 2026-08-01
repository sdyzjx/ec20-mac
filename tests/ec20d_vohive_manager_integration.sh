#!/bin/sh

# Run Vohive's real modem.Manager against ec20d's synthetic PTY. The daemon is
# unconditionally started with --mock, so --allow-arbitrary-at cannot reach USB.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOHIVE_DIR=${VOHIVE_DIR:-"$PROJECT_DIR/third_party/vohive"}
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
EC20CTL_BIN=${EC20CTL_BIN:-"$PROJECT_DIR/build/ec20ctl"}
GO_BIN=${GO_BIN:-go}

for required_binary in "$EC20D_BIN" "$EC20CTL_BIN"; do
    if [ ! -x "$required_binary" ]; then
        echo "missing executable: $required_binary" >&2
        exit 2
    fi
done
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    echo "Go executable not found: $GO_BIN" >&2
    exit 2
fi
if [ ! -f "$VOHIVE_DIR/go.mod" ]; then
    echo "invalid Vohive module directory: $VOHIVE_DIR" >&2
    exit 2
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ec20d-manager-test.XXXXXX") || exit 2
SOCKET_PATH="$TEST_TMPDIR/ec20d.sock"
DAEMON_LOG="$TEST_TMPDIR/ec20d.log"
CLIENT_LOG="$TEST_TMPDIR/ec20ctl.log"
DAEMON_PID=
PTY_PATH=

cleanup()
{
    saved_status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    case "$TEST_TMPDIR" in
        "${TMPDIR:-/tmp}"/ec20d-manager-test.*)
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
    --allow-arbitrary-at \
    --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

attempt=0
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ec20d exited before publishing its mock PTY" >&2
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
    fi
    if [ -S "$SOCKET_PATH" ]; then
        if list_output=$("$EC20CTL_BIN" --socket "$SOCKET_PATH" list 2>"$CLIENT_LOG"); then
            candidates=$(printf '%s\n' "$list_output" |
                sed 's@\\/@/@g' |
                sed -n 's@.*"\(/dev/ttys[^\"]*\)".*@\1@p')
            candidate_count=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
            if [ "$candidate_count" = "1" ]; then
                PTY_PATH=$(printf '%s\n' "$candidates" | sed -n '1p')
                break
            fi
        fi
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done

case "$PTY_PATH" in
    /dev/ttys[0-9a-f]*) ;;
    *)
        echo "invalid or missing mock PTY: ${PTY_PATH:-<empty>}" >&2
        sed -n '1,200p' "$CLIENT_LOG" >&2 || true
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
        ;;
esac
if [ ! -e "$PTY_PATH" ]; then
    echo "published mock PTY does not exist: $PTY_PATH" >&2
    exit 1
fi

if (
    cd "$VOHIVE_DIR"
    VOHIVE_EC20D_MOCK_ONLY=ec20d-mock-no-usb \
    VOHIVE_EC20D_MOCK_PTY="$PTY_PATH" \
    GOWORK=off "$GO_BIN" test -race -count=1 \
        -run '^TestDarwinManagerEC20DMockPTYLifecycle$' \
        ./internal/modem
); then
    :
else
    test_status=$?
    echo "Vohive Manager mock PTY test failed with status $test_status" >&2
    sed -n '1,240p' "$DAEMON_LOG" >&2
    exit 1
fi

if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ec20d exited during the Manager lifecycle" >&2
    sed -n '1,240p' "$DAEMON_LOG" >&2
    exit 1
fi

kill -TERM "$DAEMON_PID"
if wait "$DAEMON_PID"; then
    daemon_status=0
else
    daemon_status=$?
fi
DAEMON_PID=
if [ "$daemon_status" -ne 0 ]; then
    echo "ec20d exited with status $daemon_status" >&2
    sed -n '1,240p' "$DAEMON_LOG" >&2
    exit 1
fi
if [ -e "$SOCKET_PATH" ] || [ -e "$PTY_PATH" ]; then
    echo "ec20d did not clean up its socket or PTY" >&2
    exit 1
fi

echo "ec20d Vohive Manager mock integration: PASS"
