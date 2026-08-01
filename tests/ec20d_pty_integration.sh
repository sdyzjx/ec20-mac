#!/bin/sh

# End-to-end PTY bridge test.  --mock is mandatory here so the test never
# enumerates, opens, or writes to an attached USB modem.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
EC20CTL_BIN=${EC20CTL_BIN:-"$PROJECT_DIR/build/ec20ctl"}
EC20_PTY_SMOKE_BIN=${EC20_PTY_SMOKE_BIN:-"$PROJECT_DIR/build/ec20-pty-smoke"}

for required_binary in "$EC20D_BIN" "$EC20CTL_BIN" "$EC20_PTY_SMOKE_BIN"; do
    if [ ! -x "$required_binary" ]; then
        echo "missing executable: $required_binary" >&2
        echo "build the project first, or set the corresponding *_BIN variable" >&2
        exit 2
    fi
done

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ec20d-pty-test.XXXXXX") || exit 2
SOCKET_PATH="$TEST_TMPDIR/ec20d.sock"
DAEMON_LOG="$TEST_TMPDIR/ec20d.log"
CLIENT_LOG="$TEST_TMPDIR/ec20ctl.log"
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
        "${TMPDIR:-/tmp}"/ec20d-pty-test.*)
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

"$EC20D_BIN" --mock --pty --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

attempt=0
LIST_OUTPUT=
PTY_CANDIDATES=
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ec20d exited before publishing its mock PTY" >&2
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
    fi

    if [ -S "$SOCKET_PATH" ]; then
        if LIST_OUTPUT=$("$EC20CTL_BIN" --socket "$SOCKET_PATH" list 2>"$CLIENT_LOG"); then
            PTY_CANDIDATES=$(printf '%s\n' "$LIST_OUTPUT" |
                sed -n 's@.*"\(/dev/ttys[^"]*\)".*@\1@p')
            if [ -n "$PTY_CANDIDATES" ]; then
                break
            fi
        fi
    fi

    attempt=$((attempt + 1))
    sleep 0.05
done

if [ -z "$PTY_CANDIDATES" ]; then
    echo "timed out waiting for a PTY in devices.list" >&2
    if [ -s "$CLIENT_LOG" ]; then
        sed -n '1,200p' "$CLIENT_LOG" >&2
    fi
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi

PTY_PATH=
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
        /dev/ttys*) ;;
        *)
            echo "devices.list returned an invalid PTY path: $candidate" >&2
            exit 1
            ;;
    esac

    if [ -z "$PTY_PATH" ]; then
        PTY_PATH=$candidate
    elif [ "$PTY_PATH" != "$candidate" ]; then
        echo "devices.list returned more than one PTY path" >&2
        printf '%s\n' "$PTY_CANDIDATES" >&2
        exit 1
    fi
done <<EOF
$PTY_CANDIDATES
EOF

if [ -z "$PTY_PATH" ] || [ ! -e "$PTY_PATH" ]; then
    echo "published PTY does not exist: ${PTY_PATH:-<empty>}" >&2
    exit 1
fi

if "$EC20_PTY_SMOKE_BIN" "$PTY_PATH" AT; then
    smoke_status=0
else
    smoke_status=$?
    echo "PTY smoke client failed with exit code $smoke_status" >&2
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi

if rpc_output=$("$EC20CTL_BIN" --socket "$SOCKET_PATH" at AT 2>&1); then
    echo "ec20ctl unexpectedly acquired RPC while PTY mode owned AT" >&2
    exit 1
fi
case "$rpc_output" in
    *at.rpc*) ;;
    *)
        echo "PTY-mode RPC rejection did not explain the missing at.rpc capability" >&2
        printf '%s\n' "$rpc_output" >&2
        exit 1
        ;;
esac

if ! kill -TERM "$DAEMON_PID" 2>/dev/null; then
    echo "could not send SIGTERM to ec20d" >&2
    exit 1
fi
if wait "$DAEMON_PID"; then
    daemon_status=0
else
    daemon_status=$?
fi
DAEMON_PID=

if [ "$daemon_status" -ne 0 ]; then
    echo "ec20d exited with status $daemon_status after SIGTERM" >&2
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi
if [ -e "$SOCKET_PATH" ]; then
    echo "ec20d left its Unix socket behind after SIGTERM: $SOCKET_PATH" >&2
    exit 1
fi
if [ -e "$PTY_PATH" ]; then
    echo "ec20d left its PTY behind after SIGTERM: $PTY_PATH" >&2
    exit 1
fi

echo "ec20d mock PTY integration: PASS"
