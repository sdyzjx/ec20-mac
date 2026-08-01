#!/bin/sh

# Boot the complete embedded Vohive Web server against ec20d's deterministic
# PTY, then exercise the same login/discovery/add/AT paths used by the Vue UI.
# ec20d is unconditionally started with --mock, so this test cannot access USB.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOHIVE_DIR=${VOHIVE_DIR:-"$PROJECT_DIR/third_party/vohive"}
EC20D_BIN=${EC20D_BIN:-"$PROJECT_DIR/build/ec20d"}
GO_BIN=${GO_BIN:-go}
VOHIVE_BIN=${VOHIVE_BIN:-}
FIXTURE="$SCRIPT_DIR/fixtures/vohive-darwin-mock.yaml"
COUNTRY_FIXTURE="$SCRIPT_DIR/fixtures/mcc-mnc-table.json"

if [ ! -x "$EC20D_BIN" ]; then
    echo "missing executable: $EC20D_BIN" >&2
    exit 2
fi
if [ ! -f "$VOHIVE_DIR/go.mod" ] ||
   [ ! -f "$VOHIVE_DIR/internal/web/dist/index.html" ]; then
    echo "Vohive module or embedded Web distribution is missing: $VOHIVE_DIR" >&2
    exit 2
fi
if [ ! -f "$FIXTURE" ] || [ ! -f "$COUNTRY_FIXTURE" ]; then
    echo "missing Vohive mock fixture under $SCRIPT_DIR/fixtures" >&2
    exit 2
fi
if [ -z "$VOHIVE_BIN" ] && ! command -v "$GO_BIN" >/dev/null 2>&1; then
    echo "Go executable not found: $GO_BIN" >&2
    exit 2
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v nc >/dev/null 2>&1; then
    echo "curl and nc are required" >&2
    exit 2
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vohive-darwin-web.XXXXXX") || exit 2
SOCKET_PATH="$TEST_TMPDIR/ec20d.sock"
CONFIG_PATH="$TEST_TMPDIR/config.yaml"
DAEMON_LOG="$TEST_TMPDIR/ec20d.log"
VOHIVE_LOG="$TEST_TMPDIR/vohive.log"
HTTP_HEADERS="$TEST_TMPDIR/headers.txt"
DAEMON_PID=
VOHIVE_PID=
PTY_PATH=

cleanup()
{
    saved_status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$VOHIVE_PID" ] && kill -0 "$VOHIVE_PID" 2>/dev/null; then
        kill -TERM "$VOHIVE_PID" 2>/dev/null || true
        wait "$VOHIVE_PID" 2>/dev/null || true
    fi
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    case "$TEST_TMPDIR" in
        "${TMPDIR:-/tmp}"/vohive-darwin-web.*)
            rm -rf -- "$TEST_TMPDIR"
            ;;
        *)
            echo "refusing to remove unexpected temporary path: $TEST_TMPDIR" >&2
            ;;
    esac
    exit "$saved_status"
}

fail()
{
    echo "$1" >&2
    sed -n '1,240p' "$VOHIVE_LOG" >&2 || true
    sed -n '1,200p' "$DAEMON_LOG" >&2 || true
    exit 1
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp "$FIXTURE" "$CONFIG_PATH"
mkdir -p "$TEST_TMPDIR/data"
cp "$COUNTRY_FIXTURE" "$TEST_TMPDIR/data/mcc-mnc-table.json"

if [ -z "$VOHIVE_BIN" ]; then
    VOHIVE_BIN="$TEST_TMPDIR/vohive"
    (
        cd "$VOHIVE_DIR"
        GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH="$("$GO_BIN" env GOARCH)" \
            "$GO_BIN" build -trimpath -buildvcs=false \
                -tags "with_utls nomsgpack" \
                -o "$VOHIVE_BIN" ./cmd/vohive
    )
fi
if [ ! -x "$VOHIVE_BIN" ]; then
    echo "missing Vohive executable: $VOHIVE_BIN" >&2
    exit 2
fi

# Derive a high unprivileged port from this process. Probe a short sequence to
# avoid clashing with a concurrently running local development server.
HTTP_PORT=$((20000 + ($$ % 20000)))
attempt=0
while [ "$attempt" -lt 50 ]; do
    if ! nc -z 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1; then
        break
    fi
    HTTP_PORT=$((HTTP_PORT + 1))
    attempt=$((attempt + 1))
done
if [ "$attempt" -ge 50 ]; then
    echo "could not find an unused local HTTP port" >&2
    exit 2
fi
BASE_URL="http://127.0.0.1:$HTTP_PORT"

"$EC20D_BIN" --mock --pty --allow-arbitrary-at \
    --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

attempt=0
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        fail "ec20d exited before publishing the mock PTY"
    fi
    if [ -S "$SOCKET_PATH" ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done
if [ ! -S "$SOCKET_PATH" ]; then
    fail "timed out waiting for ec20d socket"
fi

START_DIR=$(pwd)
cd "$TEST_TMPDIR"
EC20D_SOCKET="$SOCKET_PATH" \
PROXY_SERVER_PORT="$HTTP_PORT" \
    "$VOHIVE_BIN" -c "$CONFIG_PATH" >"$VOHIVE_LOG" 2>&1 &
VOHIVE_PID=$!
cd "$START_DIR"

attempt=0
while [ "$attempt" -lt 240 ]; do
    if ! kill -0 "$VOHIVE_PID" 2>/dev/null; then
        fail "Vohive exited before its HTTP server became ready"
    fi
    if ping_response=$(curl -fsS --max-time 1 "$BASE_URL/ping" 2>/dev/null); then
        case "$ping_response" in
            *'"message":"pong"'*) break ;;
        esac
    fi
    attempt=$((attempt + 1))
    sleep 0.05
done
if [ "$attempt" -ge 240 ]; then
    fail "timed out waiting for Vohive HTTP server"
fi

INDEX_HTML=$(curl -fsS --max-time 5 "$BASE_URL/") || fail "embedded Web index request failed"
case "$INDEX_HTML" in
    *'<title>VoHive</title>'*'/assets/'*) ;;
    *) fail "embedded Web index did not contain the Vohive application shell" ;;
esac
ASSET_PATH=$(printf '%s\n' "$INDEX_HTML" |
    sed -n 's@.*src="\(/assets/[^"]*\.js\)".*@\1@p' | sed -n '1p')
if [ -z "$ASSET_PATH" ]; then
    fail "could not locate the embedded frontend entry asset"
fi
curl -fsS --max-time 5 -D "$HTTP_HEADERS" -o /dev/null "$BASE_URL$ASSET_PATH" ||
    fail "embedded frontend asset request failed"
if ! grep -qi '^content-type: application/javascript' "$HTTP_HEADERS"; then
    fail "frontend entry asset had the wrong content type"
fi

LOGIN_RESPONSE=$(curl -fsS --max-time 5 \
    -H 'Content-Type: application/json' \
    --data '{"username":"mock-admin","password":"mock-password"}' \
    "$BASE_URL/api/auth/login") || fail "Vohive login failed"
TOKEN=$(printf '%s\n' "$LOGIN_RESPONSE" |
    sed -n 's@.*"token":"\([^"]*\)".*@\1@p')
if [ -z "$TOKEN" ]; then
    fail "Vohive login response omitted its bearer token"
fi

DISCOVERY_RESPONSE=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/devices/discovered?with_imei=1") ||
    fail "Vohive device discovery failed"
case "$DISCOVERY_RESPONSE" in
    *'"degraded":true'*) fail "Darwin mock discovery was incorrectly marked degraded" ;;
esac
for expected_discovery_field in \
    '"driver_name":"ec20d-pty"' \
    '"imei":"867530900000001"' \
    '"mode":"at"' \
    '"network_capable":false'
do
    case "$DISCOVERY_RESPONSE" in
        *"$expected_discovery_field"*) ;;
        *)
            printf '%s\n' "$DISCOVERY_RESPONSE" >&2
            fail "Darwin discovery response omitted the usable AT-only EC20"
            ;;
    esac
done
PTY_PATH=$(printf '%s\n' "$DISCOVERY_RESPONSE" |
    sed -n 's@.*"at_port":"\(/dev/ttys[^"]*\)".*@\1@p')
case "$PTY_PATH" in
    /dev/ttys[0-9a-f]*) ;;
    *) fail "Darwin discovery response omitted a valid PTY path" ;;
esac

ADD_PAYLOAD=$(printf \
    '{"config":{"id":"ec20-mock","name":"EC20 macOS Mock","interface":"","modem_imei":"867530900000001","usb_path":"ec20d:mock","at_port":"%s","control_device":"","device_backend":"at","network_enabled":false}}' \
    "$PTY_PATH")
ADD_RESPONSE=$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$ADD_PAYLOAD" \
    "$BASE_URL/api/devices") || fail "adding the Darwin mock device failed"
case "$ADD_RESPONSE" in
    *'"status":"ok"'*) ;;
    *)
        printf '%s\n' "$ADD_RESPONSE" >&2
        fail "Darwin mock device add response was not successful"
        ;;
esac
case "$ADD_RESPONSE" in
    *'"started":true'*) ;;
    *)
        printf '%s\n' "$ADD_RESPONSE" >&2
        fail "Darwin mock device was saved but its worker did not start"
        ;;
esac

attempt=0
while [ "$attempt" -lt 100 ]; do
    DEVICE_RESPONSE=$(curl -fsS --max-time 5 \
        -H "Authorization: Bearer $TOKEN" \
        "$BASE_URL/api/devices") || fail "managed device list failed"
    case "$DEVICE_RESPONSE" in
        *'"id":"ec20-mock"'*'"running":true'*) break ;;
    esac
    attempt=$((attempt + 1))
    sleep 0.05
done
if [ "$attempt" -ge 100 ]; then
    fail "managed Darwin mock device never became visible"
fi

AT_RESPONSE=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data '{"cmd":"AT+CGSN","timeout_ms":3000}' \
    "$BASE_URL/api/devices/ec20-mock/actions/at") ||
    fail "managed device AT request failed"
case "$AT_RESPONSE" in
    *'"status":"ok"'*) ;;
    *)
        printf '%s\n' "$AT_RESPONSE" >&2
        fail "managed device AT request did not return success"
        ;;
esac
case "$AT_RESPONSE" in
    *'867530900000001'*) ;;
    *)
        printf '%s\n' "$AT_RESPONSE" >&2
        fail "managed device AT response omitted the deterministic IMEI"
        ;;
esac

curl -fsS --max-time 10 \
    -X DELETE \
    -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/devices/ec20-mock" >/dev/null ||
    fail "deleting the mock managed device failed"

kill -TERM "$VOHIVE_PID"
if wait "$VOHIVE_PID"; then
    vohive_status=0
else
    vohive_status=$?
fi
VOHIVE_PID=
if [ "$vohive_status" -ne 0 ]; then
    fail "Vohive did not shut down cleanly"
fi

kill -TERM "$DAEMON_PID"
if wait "$DAEMON_PID"; then
    daemon_status=0
else
    daemon_status=$?
fi
DAEMON_PID=
if [ "$daemon_status" -ne 0 ]; then
    fail "ec20d did not shut down cleanly"
fi
if [ -e "$SOCKET_PATH" ] || [ -e "$PTY_PATH" ]; then
    fail "the Web integration left its ec20d endpoints behind"
fi

echo "Vohive Darwin embedded Web integration: PASS"
