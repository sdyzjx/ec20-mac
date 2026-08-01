#!/bin/sh

# End-to-end smoke test for the ec20d IPC surface.  --mock is intentional:
# this script must never enumerate, open, or write to a real USB modem.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
EC20CTL_BIN=${EC20CTL_BIN:-"$PROJECT_DIR/build/ec20ctl"}

if [ ! -x "$EC20D_BIN" ]; then
    echo "missing executable: $EC20D_BIN" >&2
    echo "build the project first, or set EC20D_BIN" >&2
    exit 2
fi
if [ ! -x "$EC20CTL_BIN" ]; then
    echo "missing executable: $EC20CTL_BIN" >&2
    echo "build the project first, or set EC20CTL_BIN" >&2
    exit 2
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ec20d-mock-test.XXXXXX") || exit 2
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
        "${TMPDIR:-/tmp}"/ec20d-mock-test.*)
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

"$EC20D_BIN" --mock --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

attempt=0
while [ ! -S "$SOCKET_PATH" ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ec20d exited before creating its socket" >&2
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        echo "timed out waiting for ec20d socket: $SOCKET_PATH" >&2
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

run_ctl()
{
    command_name=$1
    shift

    if command_output=$("$EC20CTL_BIN" --socket "$SOCKET_PATH" "$@" 2>&1); then
        command_status=0
    else
        command_status=$?
    fi

    if [ "$command_status" -ne 0 ]; then
        echo "ec20ctl $command_name failed with exit code $command_status" >&2
        printf '%s\n' "$command_output" >&2
        sed -n '1,200p' "$DAEMON_LOG" >&2
        exit 1
    fi
    if [ -z "$command_output" ]; then
        echo "ec20ctl $command_name returned no output" >&2
        exit 1
    fi

    printf '%s\n' "$command_output"
}

run_ctl_expect_failure()
{
    command_name=$1
    shift

    if command_output=$("$EC20CTL_BIN" --socket "$SOCKET_PATH" "$@" 2>&1); then
        command_status=0
    else
        command_status=$?
    fi

    if [ "$command_status" -eq 0 ]; then
        echo "ec20ctl $command_name unexpectedly succeeded" >&2
        printf '%s\n' "$command_output" >&2
        exit 1
    fi
    printf '%s\n' "$command_output"
}

hello_output=$(run_ctl hello hello)
case "$hello_output" in
    *ec20d*) ;;
    *)
        echo "hello response does not identify ec20d" >&2
        printf '%s\n' "$hello_output" >&2
        exit 1
        ;;
esac

list_output=$(run_ctl list list)
case "$list_output" in
    *usb-03120000-1*) ;;
    *)
        echo "list response does not contain the deterministic mock device" >&2
        printf '%s\n' "$list_output" >&2
        exit 1
        ;;
esac

at_output=$(run_ctl "at AT" at AT)
case "$at_output" in
    *OK*) ;;
    *)
        echo "AT response does not contain the expected OK terminal line" >&2
        printf '%s\n' "$at_output" >&2
        exit 1
        ;;
esac

if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ec20d did not remain alive after serving the requests" >&2
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi

denied_output=$(run_ctl_expect_failure \
    "unsafe AT" at 'AT+QCFG="usbnet",1')
case "$denied_output" in
    *permission_denied*) ;;
    *)
        echo "unsafe AT failure does not report permission_denied" >&2
        printf '%s\n' "$denied_output" >&2
        exit 1
        ;;
esac

kill -TERM "$DAEMON_PID"
if ! wait "$DAEMON_PID"; then
    echo "ec20d returned a failure status after SIGTERM" >&2
    sed -n '1,200p' "$DAEMON_LOG" >&2
    exit 1
fi
DAEMON_PID=
if [ -e "$SOCKET_PATH" ]; then
    echo "ec20d left its Unix socket behind after SIGTERM" >&2
    exit 1
fi

echo "ec20d mock integration: PASS"
