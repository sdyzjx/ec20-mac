#!/bin/sh

# Exercise ec20d's PTY with the same serial library used by Vohive.  --mock is
# mandatory so this test never enumerates, opens, or writes to a USB modem.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SMOKE_DIR="$PROJECT_DIR/tools/vohive-serial-smoke"
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
EC20CTL_BIN=${EC20CTL_BIN:-"$PROJECT_DIR/build/ec20ctl"}
GO_BIN=${GO_BIN:-go}

if [ ! -x "$EC20D_BIN" ]; then
    echo "missing executable: $EC20D_BIN" >&2
    exit 2
fi
if [ ! -x "$EC20CTL_BIN" ]; then
    echo "missing executable: $EC20CTL_BIN" >&2
    exit 2
fi
if ! command -v "$GO_BIN" >/dev/null 2>&1; then
    echo "Go executable not found: $GO_BIN" >&2
    exit 2
fi
if [ ! -f "$SMOKE_DIR/go.mod" ] || [ ! -f "$SMOKE_DIR/main.go" ] ||
   [ ! -f "$SMOKE_DIR/go.sum" ]; then
    echo "incomplete Vohive serial smoke module: $SMOKE_DIR" >&2
    exit 2
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ec20d-vohive-test.XXXXXX") || exit 2
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
        "${TMPDIR:-/tmp}"/ec20d-vohive-test.*)
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
            # Foundation may JSON-escape slashes as `\/`; normalize only for
            # locating the owner-only /dev/ttys* value.
            PTY_CANDIDATES=$(printf '%s\n' "$LIST_OUTPUT" |
                sed 's@\\/@/@g' |
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

if (
    cd "$SMOKE_DIR" &&
    GOWORK=off "$GO_BIN" run -mod=readonly . "$PTY_PATH" AT
); then
    :
else
    smoke_status=$?
    echo "Vohive serial smoke failed with exit code $smoke_status" >&2
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi

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

echo "ec20d Vohive serial integration: PASS"
