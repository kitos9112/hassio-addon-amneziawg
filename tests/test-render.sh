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
[ -f "${LIB_DIR}/network.sh" ]  && . "${LIB_DIR}/network.sh"
[ -f "${LIB_DIR}/export.sh" ]   && . "${LIB_DIR}/export.sh"

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
assert_eq   "0" "$(cidr_capacity 10.13.13.0/31)" "cidr_capacity /31 -> 0"
assert_eq   "0" "$(cidr_capacity 10.13.13.0/32)" "cidr_capacity /32 -> 0 (clamped)"
assert_eq   "10.13.13.255" "$(cidr_broadcast 10.13.13.0/24)" "cidr_broadcast /24"
assert_eq   "10.0.0.3" "$(cidr_broadcast 10.0.0.0/30)" "cidr_broadcast /30"

echo "== validate.sh =="
# Run validate_all in a subshell with ad-hoc env overrides (eval is intentional:
# the args are "VAR=value" assignment strings applied before validation).
# shellcheck disable=SC2294
_validate_with() ( eval "$@"; validate_all )
assert_ok   "valid sample passes"      validate_all
assert_fail "empty endpoint_host"      _validate_with 'ENDPOINT_HOST='
assert_fail "bad vpn_subnet /33"       _validate_with 'VPN_SUBNET=10.0.0.0/33'
assert_fail "ipv6 vpn_subnet rejected" _validate_with 'VPN_SUBNET=fd00::/64'
assert_fail "bad allowed_ips"          _validate_with 'ALLOWED_IPS=0.0.0.0/99'
_dup="${DATA_DIR}/dup.tsv"; printf 'phone\t\t\nphone\t\t\n'  >"$_dup"
_oos="${DATA_DIR}/oos.tsv"; printf 'phone\t10.99.0.5\t\n'    >"$_oos"
assert_fail "duplicate client names"   _validate_with "CLIENTS_TSV=$_dup"
assert_fail "address outside subnet"   _validate_with "CLIENTS_TSV=$_oos"
assert_fail "obfs s2 == s1+56"         _validate_with 'OBFS_S1=10 OBFS_S2=66'
assert_fail "obfs header in 1..4"      _validate_with 'OBFS_H1=2 OBFS_H2=99 OBFS_H3=100 OBFS_H4=101'
assert_fail "non-numeric obfs rejected" _validate_with 'OBFS_S1=abc'
assert_fail "endpoint bad chars"       _validate_with 'ENDPOINT_HOST="a b"'
assert_fail "vpn_subnet /31 rejected"  _validate_with 'VPN_SUBNET=10.13.13.0/31'
assert_fail "vpn_subnet /32 rejected"  _validate_with 'VPN_SUBNET=10.13.13.0/32'
assert_fail "bad client_dns rejected"  _validate_with 'CLIENT_DNS="zzz"'
_net="${DATA_DIR}/net.tsv"; printf 'x\t10.13.13.0\t\n'   >"$_net"
_bc="${DATA_DIR}/bc.tsv";   printf 'x\t10.13.13.255\t\n' >"$_bc"
assert_fail "network addr rejected"    _validate_with "CLIENTS_TSV=$_net"
assert_fail "broadcast addr rejected"  _validate_with "CLIENTS_TSV=$_bc"

echo "== keys.sh: obfuscation =="
ensure_obfuscation
assert_file "$OBFS_ENV" "obfuscation.env created"
assert_ok   "jc resolved"        test -n "${OBFS_JC:-}"
assert_ok   "jmax > jmin"        test "${OBFS_JMAX}" -gt "${OBFS_JMIN}"
assert_ok   "s1 != s2"           test "${OBFS_S1}" -ne "${OBFS_S2}"
assert_ok   "s2 != s1+56"        test "${OBFS_S2}" -ne "$(( OBFS_S1 + 56 ))"
assert_ok   "h1 > 4"             test "${OBFS_H1}" -gt 4
assert_ok   "h1 != h2"           test "${OBFS_H1}" -ne "${OBFS_H2}"
_obfs1="$(cat "$OBFS_ENV")"; ensure_obfuscation; _obfs2="$(cat "$OBFS_ENV")"
assert_eq   "$_obfs1" "$_obfs2"  "obfuscation params idempotent"

echo "== keys.sh: server + clients =="
ensure_server_keys
assert_file "$SERVER_PRIV" "server private key"
assert_file "$SERVER_PUB"  "server public key"
assert_mode "$SERVER_PRIV" 600   "server private key mode 600"
_spub="$(cat "$SERVER_PUB")"; ensure_server_keys
assert_eq   "$_spub" "$(cat "$SERVER_PUB")" "server key idempotent"

resolve_clients
assert_file "$RESOLVED_TSV" "resolved tsv"
assert_eq   "2" "$(grep -c . "$RESOLVED_TSV")" "two resolved clients"
assert_eq   "10.13.13.50" "$(awk -F'\t' '$1=="laptop"{print $2}' "$RESOLVED_TSV")" "laptop fixed addr"
assert_eq   "10.13.13.2"  "$(awk -F'\t' '$1=="phone"{print $2}'  "$RESOLVED_TSV")" "phone auto addr .2"
_ppub="$(awk -F'\t' '$1=="phone"{print $3}' "$RESOLVED_TSV")"; resolve_clients
assert_eq   "$_ppub" "$(awk -F'\t' '$1=="phone"{print $3}' "$RESOLVED_TSV")" "client key idempotent"

echo "== render.sh: server =="
render_server_conf
assert_file     "$SERVER_CONF" "server conf created"
assert_mode     "$SERVER_CONF" 600 "server conf mode 600"
assert_contains "$SERVER_CONF" "^\[Interface\]" "server [Interface]"
assert_contains "$SERVER_CONF" "^ListenPort = 51820$" "server ListenPort"
assert_contains "$SERVER_CONF" "^Address = 10.13.13.1/24$" "server address .1/24"
assert_contains "$SERVER_CONF" "^PrivateKey = " "server private key line"
assert_contains "$SERVER_CONF" "^Jc = " "server obfuscation Jc"
assert_contains "$SERVER_CONF" "^H4 = " "server obfuscation H4"
assert_eq       "2" "$(grep -c '^\[Peer\]' "$SERVER_CONF")" "server has 2 peers"
assert_contains "$SERVER_CONF" "^AllowedIPs = 10.13.13.2/32$"  "phone peer /32"
assert_contains "$SERVER_CONF" "^AllowedIPs = 10.13.13.50/32$" "laptop peer /32"

echo "== render.sh: client =="
render_client_conf phone > "${DATA_DIR}/phone.conf"
assert_contains "${DATA_DIR}/phone.conf" "^Endpoint = vpn.example.org:51820$" "client endpoint"
assert_contains "${DATA_DIR}/phone.conf" "^DNS = 1.1.1.1,1.0.0.1$" "client DNS"
assert_contains "${DATA_DIR}/phone.conf" "^AllowedIPs = 0.0.0.0/0$" "client full-tunnel AllowedIPs"
assert_contains "${DATA_DIR}/phone.conf" "^Address = 10.13.13.2/32$" "client address /32"
assert_contains "${DATA_DIR}/phone.conf" "^Jc = " "client obfuscation"
assert_contains "${DATA_DIR}/phone.conf" "^PersistentKeepalive = 25$" "client keepalive"
assert_ok   "client has server pubkey"        grep -Fq "PublicKey = ${SERVER_PUBKEY}" "${DATA_DIR}/phone.conf"
assert_fail "client lacks server private key"  grep -Fq "$(cat "$SERVER_PRIV")" "${DATA_DIR}/phone.conf"
# shellcheck disable=SC2030,SC2034  # OBFS_ENABLED is read by render_client_conf (sourced)
( OBFS_ENABLED=0; render_client_conf phone ) > "${DATA_DIR}/phone-plain.conf"
assert_not_contains "${DATA_DIR}/phone-plain.conf" "^Jc = " "obfuscation-off client has no Jc"

echo "== export.sh =="
QR_IN_LOG=0 export_clients >/dev/null 2>&1
assert_file     "${EXPORT_DIR}/phone.conf" "exported phone.conf"
assert_mode     "${EXPORT_DIR}/phone.conf" 600 "exported conf mode 600"
assert_contains "${EXPORT_DIR}/phone.conf" "^Endpoint = vpn.example.org:51820$" "exported conf endpoint"
assert_file     "${EXPORT_DIR}/laptop.conf" "exported laptop.conf"
if command -v qrencode >/dev/null 2>&1; then
  assert_file "${EXPORT_DIR}/phone.png" "exported phone.png QR"
fi

echo "== keys.sh: exhaustion + render unknown =="
assert_fail "render_client_conf unknown name" render_client_conf no-such-client
# /30 has capacity 2 (server .1 + one client .2); 3 auto clients must fail loudly.
_resolve_with() ( eval "$1"; resolve_clients )
_exh="${DATA_DIR}/exh.tsv"; printf 'e1\t\t\ne2\t\t\ne3\t\t\n' >"$_exh"
assert_fail "subnet exhaustion fails loudly" _resolve_with "VPN_SUBNET=10.0.0.0/30 CLIENTS_TSV=$_exh"

assert_summary
