#!/usr/bin/env bash
# test-render.sh — pure-logic tests for the AmneziaWG add-on libraries.
# Runs without root and (if awg/wg are absent) without real key tooling by
# pre-seeding fake keys. Covers common.sh, validate.sh, keys.sh, render.sh.
#
# Usage: bash tests/test-render.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/amneziawg/rootfs/usr/lib/amneziawg"
SAMPLE="${SCRIPT_DIR}/options.sample.json"

# shellcheck source=tests/lib/assert.sh
. "${SCRIPT_DIR}/lib/assert.sh"

# Isolated, disposable state for this run.
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awg-data.XXXXXX")"
EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awg-export.XXXXXX")"
export DATA_DIR EXPORT_DIR
IFACE="awg0"; export IFACE
CLIENTS_TSV="${DATA_DIR}/.clients.input.tsv"; export CLIENTS_TSV
cleanup() { rm -rf "${DATA_DIR}" "${EXPORT_DIR}"; }
trap cleanup EXIT

# --- Parse options.sample.json into the env + TSV contract --------------------
parse_options() { # json envfile tsv
  local json="$1" envfile="$2" tsv="$3"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$json" "$envfile" "$tsv" <<'PY'
import json, sys, shlex
data = json.load(open(sys.argv[1]))
def q(v): return shlex.quote(str(v))
with open(sys.argv[2], 'w') as e:
    def w(k, v): e.write(f'export {k}={q(v)}\n')
    w('SERVER_PORT', data['server_port'])
    w('ENDPOINT_HOST', data['endpoint_host'])
    w('VPN_SUBNET', data['vpn_subnet'])
    w('CLIENT_DNS', ' '.join(data.get('client_dns', [])))
    w('ALLOWED_IPS', data['allowed_ips'])
    w('MTU', data['mtu'])
    w('PERSISTENT_KEEPALIVE', data['persistent_keepalive'])
    w('ENABLE_NAT', '1' if data.get('enable_nat', True) else '0')
    w('REGENERATE_CLIENTS', '1' if data.get('regenerate_clients', False) else '0')
    ob = data.get('obfuscation', {})
    w('OBFS_ENABLED', '1' if ob.get('enabled', True) else '0')
    for p in ('jc', 'jmin', 'jmax', 's1', 's2', 'h1', 'h2', 'h3', 'h4'):
        w('OBFS_' + p.upper(), ob.get(p, ''))
with open(sys.argv[3], 'w') as t:
    for c in data.get('clients', []):
        t.write('\t'.join([c['name'], str(c.get('address', '')),
                            str(c.get('allowed_ips', ''))]) + '\n')
PY
  elif command -v jq >/dev/null 2>&1; then
    {
      echo "export SERVER_PORT=$(jq -r '.server_port' "$json")"
      echo "export ENDPOINT_HOST=$(jq -r '.endpoint_host|@sh' "$json")"
      echo "export VPN_SUBNET=$(jq -r '.vpn_subnet|@sh' "$json")"
      echo "export CLIENT_DNS=$(jq -r '.client_dns|join(" ")|@sh' "$json")"
      echo "export ALLOWED_IPS=$(jq -r '.allowed_ips|@sh' "$json")"
      echo "export MTU=$(jq -r '.mtu' "$json")"
      echo "export PERSISTENT_KEEPALIVE=$(jq -r '.persistent_keepalive' "$json")"
      echo "export ENABLE_NAT=$(jq -r 'if .enable_nat then 1 else 0 end' "$json")"
      echo "export REGENERATE_CLIENTS=$(jq -r 'if .regenerate_clients then 1 else 0 end' "$json")"
      echo "export OBFS_ENABLED=$(jq -r 'if .obfuscation.enabled then 1 else 0 end' "$json")"
      for p in jc jmin jmax s1 s2 h1 h2 h3 h4; do
        echo "export OBFS_$(echo "$p" | tr '[:lower:]' '[:upper:]')=$(jq -r ".obfuscation.${p} // \"\"" "$json")"
      done
    } >"$envfile"
    jq -r '.clients[] | [.name, (.address // ""), (.allowed_ips // "")] | @tsv' "$json" >"$tsv"
  else
    return 1
  fi
}

if ! parse_options "$SAMPLE" "${DATA_DIR}/env.sh" "$CLIENTS_TSV"; then
  echo "SKIP: neither python3 nor jq available to parse fixtures" >&2
  exit 0
fi
# shellcheck disable=SC1091
. "${DATA_DIR}/env.sh"

# Key tooling: use awg/wg if present, otherwise tell keys.sh to fake keys.
if command -v awg >/dev/null 2>&1; then KEYGEN="awg"
elif command -v wg >/dev/null 2>&1; then KEYGEN="wg"
else KEYGEN=""; FAKE_KEYS=1; export FAKE_KEYS; fi
export KEYGEN
export SKIP_TUN_CHECK=1   # no /dev/net/tun on the dev host

# Source libraries that exist (later tasks add the rest).
# shellcheck source=amneziawg/rootfs/usr/lib/amneziawg/common.sh
. "${LIB_DIR}/common.sh"
[ -f "${LIB_DIR}/validate.sh" ] && . "${LIB_DIR}/validate.sh"
[ -f "${LIB_DIR}/keys.sh" ]     && . "${LIB_DIR}/keys.sh"
[ -f "${LIB_DIR}/render.sh" ]   && . "${LIB_DIR}/render.sh"

echo "== common.sh helpers =="
assert_ok   "is_valid_cidr accepts 10.13.13.0/24" is_valid_cidr "10.13.13.0/24"
assert_ok   "is_valid_cidr accepts fd00::/64"     is_valid_cidr "fd00::/64"
assert_fail "is_valid_cidr rejects /33"           is_valid_cidr "10.13.13.0/33"
assert_fail "is_valid_cidr rejects bad octet"     is_valid_cidr "999.1.1.1/24"
assert_fail "is_valid_cidr rejects non-cidr"      is_valid_cidr "notacidr"
assert_ok   "is_valid_ipv4 accepts 10.0.0.1"      is_valid_ipv4 "10.0.0.1"
assert_fail "is_valid_ipv4 rejects .256"          is_valid_ipv4 "10.0.0.256"
assert_eq   "10.13.13.1"  "$(cidr_host 10.13.13.0/24 1)"  "cidr_host index 1"
assert_eq   "10.13.13.2"  "$(cidr_host 10.13.13.0/24 2)"  "cidr_host index 2"
assert_eq   "10.13.13.50" "$(cidr_host 10.13.13.0/24 50)" "cidr_host index 50"
assert_ok   "cidr_contains in-range"  cidr_contains "10.13.13.0/24" "10.13.13.50"
assert_fail "cidr_contains out-range" cidr_contains "10.13.13.0/24" "10.13.14.5"
assert_eq   "254" "$(cidr_capacity 10.13.13.0/24)" "cidr_capacity /24"
R="$(rand_int 1 10)"; assert_ok "rand_int 1..10 in range" test "$R" -ge 1 -a "$R" -le 10
assert_eq   "7" "$(rand_int 7 7)" "rand_int degenerate range"

# ---- validate.sh / keys.sh / render.sh assertions appended in later tasks ----
__run_validate_tests 2>/dev/null || true
__run_keys_tests     2>/dev/null || true
__run_render_tests   2>/dev/null || true

assert_summary
