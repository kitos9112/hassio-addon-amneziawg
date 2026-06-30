#!/usr/bin/env bash
# common.sh — shared helpers + the env/file contract for the AmneziaWG add-on.
# Sourced by the s6 service scripts (run/finish) and by the test harness.
# Pure POSIX-ish bash; must work under macOS bash 3.2 and Alpine bash 5.

# --- Paths / contract defaults ------------------------------------------------
: "${DATA_DIR:=/data}"
: "${EXPORT_DIR:=/config/clients}"
: "${IFACE:=awg0}"
: "${CLIENTS_TSV:=${DATA_DIR}/.clients.input.tsv}"
: "${CONFIG_SHARE:=/config}"
# shellcheck disable=SC2034
KEY_EXPORT_DIR="${CONFIG_SHARE}/keys"
# shellcheck disable=SC2034
BUNDLE_OUT="${CONFIG_SHARE}/amneziawg-backup.awg"
# shellcheck disable=SC2034
BUNDLE_IN="${CONFIG_SHARE}/amneziawg-restore.awg"
# shellcheck disable=SC2034
CLIENT_IMPORT_TSV="${DATA_DIR}/.clients.import.tsv"

# These are consumed by the sibling libraries sourced alongside this one
# (keys.sh, render.sh, network.sh, export.sh), not within common.sh itself.
# shellcheck disable=SC2034
RESOLVED_TSV="${DATA_DIR}/.clients.resolved.tsv"
# shellcheck disable=SC2034
SERVER_CONF="${DATA_DIR}/${IFACE}.conf"
# shellcheck disable=SC2034
SERVER_PRIV="${DATA_DIR}/server_private.key"
# shellcheck disable=SC2034
SERVER_PUB="${DATA_DIR}/server_public.key"
# shellcheck disable=SC2034
OBFS_ENV="${DATA_DIR}/obfuscation.env"
# shellcheck disable=SC2034
RUNTIME_STATE="${DATA_DIR}/.runtime"
# shellcheck disable=SC2034
CLIENT_KEY_DIR="${DATA_DIR}/clients"

# --- Logging ------------------------------------------------------------------
# Wrap bashio when present (inside Home Assistant); otherwise plain stderr.
if command -v bashio::log.info >/dev/null 2>&1; then
  log_info()  { bashio::log.info    "$*"; }
  log_warn()  { bashio::log.warning "$*"; }
  log_error() { bashio::log.error   "$*"; }
  log_fatal() { bashio::log.fatal   "$*"; }
else
  log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
  log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
  log_error() { printf '[ERROR] %s\n' "$*" >&2; }
  log_fatal() { printf '[FATAL] %s\n' "$*" >&2; }
fi

die() { log_fatal "$*"; exit 1; }

# --- Randomness ---------------------------------------------------------------
# rand_int MIN MAX -> inclusive random integer in [MIN, MAX]
rand_int() {
  local min="$1" max="$2" range r
  range=$(( max - min + 1 ))
  if [ "$range" -le 0 ]; then echo "$min"; return; fi
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  echo $(( min + (r % range) ))
}

# --- Hashing ------------------------------------------------------------------
key_fingerprint() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-11
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-11
  fi
}

# is_valid_wg_key KEY -> success if KEY is a 44-char base64 WireGuard key (32 bytes).
is_valid_wg_key() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9+/]{43}=$'
}

# is_valid_client_name NAME -> success if NAME matches the add-on client-name schema
# (a-z A-Z 0-9 then up to 31 more of a-z A-Z 0-9 -). Guards FS paths built from
# bundle-supplied names.
is_valid_client_name() {
  printf '%s' "$1" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$'
}

# --- IPv4 / CIDR math (IPv4 only for arithmetic; IPv6 validated loosely) -------
is_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  for o in "$@"; do
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
  done
  return 0
}

cidr_prefix() { echo "${1#*/}"; }

is_valid_cidr() {
  local cidr="$1" addr prefix
  [[ "$cidr" == */* ]] || return 1
  addr="${cidr%/*}"; prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  if [[ "$addr" == *:* ]]; then
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    return 0
  fi
  is_valid_ipv4 "$addr" || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
  return 0
}

_ipv4_to_int() {
  local IFS=. a b c d
  read -r a b c d <<EOF
$1
EOF
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

_int_to_ipv4() {
  local n="$1"
  echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"
}

_cidr_mask() {
  local prefix="$1"
  if [ "$prefix" -eq 0 ]; then echo 0; else
    echo $(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
}

# cidr_host SUBNET INDEX -> Nth address after the network base (INDEX 1 == .1).
cidr_host() {
  local subnet="$1" index="$2" base prefix mask net
  base="${subnet%/*}"; prefix="${subnet#*/}"
  mask="$(_cidr_mask "$prefix")"
  net=$(( $(_ipv4_to_int "$base") & mask ))
  _int_to_ipv4 $(( net + index ))
}

# cidr_contains SUBNET IP -> success if IP is inside SUBNET (IPv4)
cidr_contains() {
  local subnet="$1" ip="$2" prefix mask net ipnet
  prefix="${subnet#*/}"
  mask="$(_cidr_mask "$prefix")"
  net=$(( $(_ipv4_to_int "${subnet%/*}") & mask ))
  ipnet=$(( $(_ipv4_to_int "$ip") & mask ))
  [ "$net" -eq "$ipnet" ]
}

# cidr_capacity SUBNET -> usable host count (excludes network + broadcast)
cidr_capacity() {
  local prefix="${1#*/}" cap
  cap=$(( (1 << (32 - prefix)) - 2 ))
  [ "$cap" -lt 0 ] && cap=0
  echo "$cap"
}

# cidr_broadcast SUBNET -> the IPv4 broadcast address of the subnet
cidr_broadcast() {
  local subnet="$1" prefix mask net
  prefix="${subnet#*/}"
  mask="$(_cidr_mask "$prefix")"
  net=$(( $(_ipv4_to_int "${subnet%/*}") & mask ))
  _int_to_ipv4 $(( net | (0xFFFFFFFF ^ mask) ))
}
