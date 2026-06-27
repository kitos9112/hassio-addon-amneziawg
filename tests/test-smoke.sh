#!/usr/bin/env bash
# test-smoke.sh — integration smoke test in a privileged container.
# Builds the add-on image, brings the interface up with real amneziawg-go,
# asserts NAT/forwarding/interface, then tears down and asserts cleanup.
#
# Requires Docker + the ability to --cap-add=NET_ADMIN --device=/dev/net/tun.
# Skips cleanly (exit 0) if Docker is unavailable.
#
# Usage: bash tests/test-smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMG="awg-addon-smoke:test"
BASE="${BUILD_FROM:-ghcr.io/hassio-addons/base:19.0.0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available — cannot run the container smoke test." >&2
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not running — cannot run the container smoke test." >&2
  exit 0
fi

echo "==> Building image (${IMG}) from ${BASE} … this clones + compiles amnezia* and may take a few minutes."
if ! docker build --build-arg "BUILD_FROM=${BASE}" -t "${IMG}" "${REPO_ROOT}/amneziawg"; then
  echo "FAIL: docker build failed." >&2
  exit 1
fi

INNER="$(mktemp "${TMPDIR:-/tmp}/awg-smoke.XXXXXX")"
trap 'rm -f "${INNER}"' EXIT
cat > "${INNER}" <<'SMOKE'
set -eu
export DATA_DIR=/data EXPORT_DIR=/config/clients IFACE=awg0
export SERVER_PORT=51820 ENDPOINT_HOST=test.example.org VPN_SUBNET=10.13.13.0/24
export CLIENT_DNS="1.1.1.1" ALLOWED_IPS=0.0.0.0/0 MTU=1420 PERSISTENT_KEEPALIVE=25
export ENABLE_NAT=1 REGENERATE_CLIENTS=0 OBFS_ENABLED=1 QR_IN_LOG=0
export SKIP_TUN_CHECK=0 KEYGEN=awg
export CLIENTS_TSV=/data/.clients.input.tsv
mkdir -p /data /config/clients
printf 'phone\t\t\nlaptop\t10.13.13.50\t\n' > "$CLIENTS_TSV"

LIB=/usr/lib/amneziawg
. "$LIB/common.sh"; . "$LIB/validate.sh"; . "$LIB/keys.sh"
. "$LIB/render.sh"; . "$LIB/network.sh"; . "$LIB/export.sh"

fail() { echo "ASSERT FAIL: $1"; exit 1; }

echo "--> versions"; amneziawg-go --version 2>/dev/null || true; awg --version || true

echo "--> validate + render + bring up"
validate_all                       || fail "validate_all"
ensure_obfuscation
ensure_server_keys
resolve_clients
render_server_conf
nat_up                             || fail "nat_up"
awg-quick up "$SERVER_CONF"        || fail "awg-quick up"

echo "--> assertions (interface / NAT / forwarding)"
awg show "$IFACE" >/dev/null       || fail "awg show $IFACE"
awg show "$IFACE" | grep -q "listening port: 51820" || fail "listen port 51820"
test "$(awg show "$IFACE" peers | wc -l)" -eq 2 || fail "expected 2 peers"
iptables -t nat -S | grep -q 'amneziawg-addon' || fail "masquerade rule missing"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || fail "ip_forward != 1"

echo "--> export"
export_clients
[ -f /config/clients/phone.conf ]  || fail "phone.conf not exported"
[ -f /config/clients/laptop.conf ] || fail "laptop.conf not exported"
grep -q '^Endpoint = test.example.org:51820$' /config/clients/phone.conf || fail "client endpoint"

echo "--> teardown + cleanup assertions"
awg-quick down "$SERVER_CONF"      || fail "awg-quick down"
nat_down                           || fail "nat_down"
awg show "$IFACE" >/dev/null 2>&1  && fail "interface still present after down"
iptables -t nat -S | grep -q 'amneziawg-addon' && fail "NAT rule not removed"

echo "SMOKE OK"
SMOKE

echo "==> Running container smoke test (privileged: NET_ADMIN + /dev/net/tun) …"
if docker run --rm -i \
      --cap-add=NET_ADMIN \
      --device=/dev/net/tun \
      --sysctl net.ipv4.ip_forward=0 \
      --entrypoint /bin/bash \
      "${IMG}" -s < "${INNER}"; then
  echo "PASS: container smoke test succeeded."
  exit 0
else
  echo "FAIL: container smoke test failed." >&2
  exit 1
fi
