#!/usr/bin/env bash
# test-keyio.sh — unit tests for key import/export (common.sh helpers, keys.sh
# pre-seed, import.sh, export.sh key paths). Pure-logic: runs without root/TUN,
# using the fake-key path when awg/wg are absent.
# Usage: bash tests/test-keyio.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/amneziawg/rootfs/usr/lib/amneziawg"

# shellcheck source=tests/lib/assert.sh
. "${SCRIPT_DIR}/lib/assert.sh"

# Two well-formed example WireGuard keys (WireGuard docs) for paste tests.
TEST_PRIV="yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
TEST_PSK="FpCBjFhYxBxIb/cQfHYpkzwY9bnX5Zq0n3pVH8Qe1mE="

# Run restore_bundle in a subshell with ad-hoc env assignments (eval is intentional).
# shellcheck disable=SC2294
_restore_with() ( eval "$1"; restore_bundle )

# Global runtime contract.
IFACE="awg0"; export IFACE
OBFS_ENABLED=1; export OBFS_ENABLED
VPN_SUBNET="10.13.13.0/24"; ALLOWED_IPS="0.0.0.0/0"; export VPN_SUBNET ALLOWED_IPS
export SKIP_TUN_CHECK=1
if command -v awg >/dev/null 2>&1; then KEYGEN="awg"
elif command -v wg  >/dev/null 2>&1; then KEYGEN="wg"
else KEYGEN=""; fi
export KEYGEN

# shellcheck source=amneziawg/rootfs/usr/lib/amneziawg/common.sh
. "${LIB_DIR}/common.sh"
[ -f "${LIB_DIR}/keys.sh" ]   && . "${LIB_DIR}/keys.sh"
[ -f "${LIB_DIR}/import.sh" ] && . "${LIB_DIR}/import.sh"
[ -f "${LIB_DIR}/export.sh" ] && . "${LIB_DIR}/export.sh"
[ -f "${LIB_DIR}/render.sh" ] && . "${LIB_DIR}/render.sh"

# fresh_data — disposable /data + /config share for one scenario; re-derives the
# whole path contract so each scenario is fully isolated.
fresh_data() {
  DATA_DIR="$(mktemp -d "$SCRATCH/data.XXXXXX")"
  CONFIG_SHARE="$(mktemp -d "$SCRATCH/cfg.XXXXXX")"
  export DATA_DIR CONFIG_SHARE
  EXPORT_DIR="${CONFIG_SHARE}/clients"
  SERVER_PRIV="${DATA_DIR}/server_private.key"
  SERVER_PUB="${DATA_DIR}/server_public.key"
  SERVER_CONF="${DATA_DIR}/${IFACE}.conf"
  OBFS_ENV="${DATA_DIR}/obfuscation.env"
  CLIENT_KEY_DIR="${DATA_DIR}/clients"
  CLIENTS_TSV="${DATA_DIR}/.clients.input.tsv"
  CLIENT_IMPORT_TSV="${DATA_DIR}/.clients.import.tsv"
  RESOLVED_TSV="${DATA_DIR}/.clients.resolved.tsv"
  KEY_EXPORT_DIR="${CONFIG_SHARE}/keys"
  BUNDLE_OUT="${CONFIG_SHARE}/amneziawg-backup.awg"
  BUNDLE_IN="${CONFIG_SHARE}/amneziawg-restore.awg"
  export EXPORT_DIR SERVER_PRIV SERVER_PUB SERVER_CONF OBFS_ENV CLIENT_KEY_DIR \
         CLIENTS_TSV CLIENT_IMPORT_TSV RESOLVED_TSV KEY_EXPORT_DIR BUNDLE_OUT BUNDLE_IN
  # Clear obfuscation env so a restored obfuscation.env is honoured, not shadowed.
  unset OBFS_JC OBFS_JMIN OBFS_JMAX OBFS_S1 OBFS_S2 OBFS_H1 OBFS_H2 OBFS_H3 OBFS_H4 SERVER_PUBKEY
  mkdir -p "$DATA_DIR" "$CONFIG_SHARE"
}
# Disposable scratch root for the whole run; all temp dirs + bundles live here
# (single dir keeps cleanup bash-3.2 safe under `set -u`).
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/awg-kio.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

echo "== common.sh: is_valid_wg_key =="
assert_ok   "accepts example priv"  is_valid_wg_key "$TEST_PRIV"
assert_ok   "accepts example psk"   is_valid_wg_key "$TEST_PSK"
assert_fail "rejects too short"     is_valid_wg_key "abc="
assert_fail "rejects no padding"    is_valid_wg_key "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmkk"
assert_fail "rejects empty"         is_valid_wg_key ""

echo "== keys.sh: pre-seed support =="
fresh_data
printf '%s\n' "$TEST_PRIV" > "$SERVER_PRIV"; chmod 600 "$SERVER_PRIV"
ensure_server_keys
assert_file "$SERVER_PUB" "server pub derived from pre-seeded priv"
assert_eq   "$TEST_PRIV" "$(cat "$SERVER_PRIV")" "pre-seeded server priv kept"

fresh_data
mkdir -p "$CLIENT_KEY_DIR/phone"
printf '%s\n' "$TEST_PSK" > "$CLIENT_KEY_DIR/phone/preshared.key"
chmod 600 "$CLIENT_KEY_DIR/phone/preshared.key"
printf 'phone\t\t\n' > "$CLIENTS_TSV"
resolve_clients
assert_eq   "$TEST_PSK" "$(cat "$CLIENT_KEY_DIR/phone/preshared.key")" "pre-seeded client psk kept"
assert_file "$CLIENT_KEY_DIR/phone/private.key" "client priv generated beside seeded psk"
assert_file "$CLIENT_KEY_DIR/phone/public.key"  "client pub derived beside seeded psk"

echo "== import.sh: paste-in server key =="
fresh_data
IMPORT_SERVER_KEY="$TEST_PRIV" KEY_IMPORT_OVERWRITE=0 import_server_key
ensure_server_keys
assert_eq "$TEST_PRIV" "$(cat "$SERVER_PRIV")" "fill-empty imports server priv"
assert_file "$SERVER_PUB" "server pub derived after import"

# fill-empty must NOT clobber an existing different key
# (TEST_PSK is a valid key that differs from TEST_PRIV)
OTHER="$TEST_PSK"
fresh_data
printf '%s\n' "$OTHER" > "$SERVER_PRIV"; chmod 600 "$SERVER_PRIV"
IMPORT_SERVER_KEY="$TEST_PRIV" KEY_IMPORT_OVERWRITE=0 import_server_key
assert_eq "$OTHER" "$(cat "$SERVER_PRIV")" "overwrite=0 keeps existing server priv"

# overwrite=1 replaces and forces pub re-derivation
fresh_data
printf '%s\n' "$OTHER" > "$SERVER_PRIV"; chmod 600 "$SERVER_PRIV"
printf '%s\n' "stale" > "$SERVER_PUB"
IMPORT_SERVER_KEY="$TEST_PRIV" KEY_IMPORT_OVERWRITE=1 import_server_key
assert_eq "$TEST_PRIV" "$(cat "$SERVER_PRIV")" "overwrite=1 replaces server priv"
assert_ok "overwrite drops stale pub" test ! -f "$SERVER_PUB"

echo "== import.sh: invalid key rejected =="
fresh_data
IMPORT_SERVER_KEY="not-a-key" KEY_IMPORT_OVERWRITE=0 import_server_key
assert_ok "invalid server key not written" test ! -f "$SERVER_PRIV"

echo "== import.sh: paste-in client keys =="
fresh_data
printf 'phone\t%s\t%s\n' "$TEST_PRIV" "$TEST_PSK" > "$CLIENT_IMPORT_TSV"
KEY_IMPORT_OVERWRITE=0 import_client_keys
assert_eq "$TEST_PRIV" "$(cat "$CLIENT_KEY_DIR/phone/private.key")" "client priv imported"
assert_eq "$TEST_PSK"  "$(cat "$CLIENT_KEY_DIR/phone/preshared.key")" "client psk imported"
printf 'phone\t\t\n' > "$CLIENTS_TSV"
resolve_clients
assert_file "$CLIENT_KEY_DIR/phone/public.key" "client pub derived after import + resolve"

echo "== export.sh: individual key files + plaintext bundle =="
fresh_data
printf 'phone\t\t\nlaptop\t10.13.13.50\t\n' > "$CLIENTS_TSV"
ensure_obfuscation; ensure_server_keys; resolve_clients
KEY_EXPORT_PASSPHRASE="" export_keys
assert_file "$KEY_EXPORT_DIR/server/private.key" "exported server priv"
assert_mode "$KEY_EXPORT_DIR/server/private.key" 600 "exported server priv mode 600"
assert_file "$KEY_EXPORT_DIR/clients/phone/private.key" "exported phone priv"
assert_file "$KEY_EXPORT_DIR/clients/phone/preshared.key" "exported phone psk"
assert_file "$BUNDLE_OUT" "plaintext bundle written"
assert_ok   "bundle is JSON keybundle" sh -c "jq -e '.format==\"amneziawg-keybundle\"' '$BUNDLE_OUT'"
assert_eq   "2" "$(jq '.clients | length' "$BUNDLE_OUT")" "bundle has 2 clients"
assert_ok   "bundle carries obfuscation jc" sh -c "test -n \"\$(jq -r '.obfuscation.jc' '$BUNDLE_OUT')\""
assert_eq   "$(cat "$SERVER_PRIV")" "$(jq -r '.server.private_key' "$BUNDLE_OUT")" "bundle server priv matches"

echo "== restore_bundle: plaintext round-trip =="
fresh_data
printf 'phone\t\t\nlaptop\t10.13.13.50\t\n' > "$CLIENTS_TSV"
ensure_obfuscation; ensure_server_keys; resolve_clients
SRV1="$(cat "$SERVER_PRIV")"
PH_PRIV1="$(cat "$CLIENT_KEY_DIR/phone/private.key")"
PH_PSK1="$(cat "$CLIENT_KEY_DIR/phone/preshared.key")"
JC1="$OBFS_JC"
KEY_EXPORT_PASSPHRASE="" write_bundle
SAVED="$SCRATCH/saved.awg"; cp "$BUNDLE_OUT" "$SAVED"

fresh_data
cp "$SAVED" "$BUNDLE_IN"
printf 'phone\t\t\nlaptop\t10.13.13.50\t\n' > "$CLIENTS_TSV"
KEY_IMPORT_RESTORE=1 KEY_IMPORT_OVERWRITE=0 restore_bundle
ensure_obfuscation; ensure_server_keys; resolve_clients
assert_eq "$SRV1"     "$(cat "$SERVER_PRIV")" "restored server priv matches"
assert_eq "$PH_PRIV1" "$(cat "$CLIENT_KEY_DIR/phone/private.key")" "restored phone priv matches"
assert_eq "$PH_PSK1"  "$(cat "$CLIENT_KEY_DIR/phone/preshared.key")" "restored phone psk matches"
assert_eq "$JC1"      "$OBFS_JC" "restored obfuscation jc matches"

echo "== restore_bundle: missing file is fatal =="
fresh_data
assert_fail "restore with no bundle fails" _restore_with 'KEY_IMPORT_RESTORE=1'

# openssl -pbkdf2 capability probe (skip encrypted asserts where unsupported, e.g. old LibreSSL)
if BUNDLE_PASS=x openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:BUNDLE_PASS \
     -in /dev/null -out /dev/null 2>/dev/null; then HAVE_SSL=1; else HAVE_SSL=0; fi

if [ "$HAVE_SSL" = 1 ]; then
  echo "== restore_bundle: encrypted round-trip =="
  fresh_data
  printf 'phone\t\t\n' > "$CLIENTS_TSV"
  ensure_obfuscation; ensure_server_keys; resolve_clients
  SRV2="$(cat "$SERVER_PRIV")"
  KEY_EXPORT_PASSPHRASE="s3cret-pass" write_bundle
  assert_eq "Salted__" "$(head -c 8 "$BUNDLE_OUT")" "encrypted bundle has openssl magic"
  ENC="$SCRATCH/enc.awg"; cp "$BUNDLE_OUT" "$ENC"

  fresh_data
  cp "$ENC" "$BUNDLE_IN"
  printf 'phone\t\t\n' > "$CLIENTS_TSV"
  assert_fail "wrong passphrase fails"   _restore_with 'KEY_IMPORT_RESTORE=1 KEY_IMPORT_PASSPHRASE=wrong'
  assert_fail "empty passphrase fails"   _restore_with 'KEY_IMPORT_RESTORE=1'
  KEY_IMPORT_RESTORE=1 KEY_IMPORT_PASSPHRASE="s3cret-pass" restore_bundle
  ensure_server_keys
  assert_eq "$SRV2" "$(cat "$SERVER_PRIV")" "encrypted bundle round-trip server priv"
else
  echo "  SKIP encrypted-bundle asserts (openssl -pbkdf2 unavailable here)"
fi

echo "== validate.sh: key import preconditions =="
[ -f "${LIB_DIR}/validate.sh" ] && . "${LIB_DIR}/validate.sh"
fresh_data
# Minimum valid base config for validate_all to reach the key checks.
SERVER_PORT=51820 ENDPOINT_HOST="vpn.example.org" MTU=1420 PERSISTENT_KEEPALIVE=25
CLIENT_DNS="1.1.1.1"; export SERVER_PORT ENDPOINT_HOST MTU PERSISTENT_KEEPALIVE CLIENT_DNS
: > "$CLIENTS_TSV"
_validate_kio() ( eval "$1"; validate_all )
assert_ok   "clean config passes"          _validate_kio ':'
assert_fail "bad server_private_key"        _validate_kio 'IMPORT_SERVER_KEY=not-a-key'
printf 'phone\tnot-a-key\t\n' > "$CLIENT_IMPORT_TSV"
assert_fail "bad client private_key"        _validate_kio ':'
: > "$CLIENT_IMPORT_TSV"
assert_fail "restore on, file missing"      _validate_kio 'KEY_IMPORT_RESTORE=1'
printf 'Salted__xxxxx' > "$BUNDLE_IN"
assert_fail "encrypted restore, no pass"    _validate_kio 'KEY_IMPORT_RESTORE=1'
assert_ok   "encrypted restore, with pass"  _validate_kio 'KEY_IMPORT_RESTORE=1 KEY_IMPORT_PASSPHRASE=x'

echo "== validate.sh: regenerate_clients vs import are mutually exclusive =="
fresh_data
SERVER_PORT=51820 ENDPOINT_HOST="vpn.example.org" MTU=1420 PERSISTENT_KEEPALIVE=25 CLIENT_DNS="1.1.1.1"
export SERVER_PORT ENDPOINT_HOST MTU PERSISTENT_KEEPALIVE CLIENT_DNS
: > "$CLIENTS_TSV"; : > "$CLIENT_IMPORT_TSV"
assert_fail "regenerate + server-key import rejected" _validate_kio "REGENERATE_CLIENTS=1 IMPORT_SERVER_KEY=$TEST_PRIV"
assert_fail "regenerate + restore rejected"           _validate_kio 'REGENERATE_CLIENTS=1 KEY_IMPORT_RESTORE=1'
assert_ok   "regenerate alone still valid"            _validate_kio 'REGENERATE_CLIENTS=1'

echo "== restore_bundle: rejects traversal client name =="
fresh_data
jq -n --arg pk "$TEST_PRIV" --arg name "../evil" \
  '{format:"amneziawg-keybundle",version:1,server:{private_key:$pk},obfuscation:{jc:"5"},clients:[{name:$name,private_key:$pk,preshared_key:$pk}]}' > "$BUNDLE_IN"
KEY_IMPORT_RESTORE=1 KEY_IMPORT_OVERWRITE=0 restore_bundle
assert_ok   "no key written outside CLIENT_KEY_DIR" test ! -e "$DATA_DIR/evil/private.key"
assert_ok   "traversal client dir not created"      test ! -d "$DATA_DIR/evil"
assert_file "$SERVER_PRIV" "server key still restored despite the bad client"

assert_summary
