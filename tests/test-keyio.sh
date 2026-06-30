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

assert_summary
