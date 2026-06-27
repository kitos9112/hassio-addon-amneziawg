#!/usr/bin/env bash
# keys.sh — idempotent key + obfuscation parameter generation/persistence.
# Requires common.sh. Uses $KEYGEN (awg|wg) when set; otherwise synthesises
# deterministic fake keys (test-only path on hosts without WireGuard tooling).

# --- key tooling --------------------------------------------------------------
_fake_key() { # seed -> 44-char base64-ish deterministic string
  local h
  if command -v sha256sum >/dev/null 2>&1; then
    h="$(printf '%s' "$1" | sha256sum | cut -c1-43)"
  else
    h="$(printf '%s' "$1" | shasum -a 256 | cut -c1-43)"
  fi
  printf '%s=\n' "$h"
}

_gen_privkey() {
  if [ -n "${KEYGEN:-}" ]; then "$KEYGEN" genkey
  else _fake_key "priv-$(rand_int 0 2147483647)-$(rand_int 0 2147483647)"; fi
}

_pubkey() { # reads private key on stdin
  if [ -n "${KEYGEN:-}" ]; then "$KEYGEN" pubkey
  else local k; read -r k; _fake_key "pub-of-${k}"; fi
}

_genpsk() {
  if [ -n "${KEYGEN:-}" ]; then "$KEYGEN" genpsk
  else _fake_key "psk-$(rand_int 0 2147483647)-$(rand_int 0 2147483647)"; fi
}

# --- obfuscation --------------------------------------------------------------
# Precedence per parameter: explicit env (user option) > persisted file > generated.
ensure_obfuscation() {
  if [ "${OBFS_ENABLED:-1}" != "1" ]; then
    rm -f "$OBFS_ENV" 2>/dev/null || true
    return 0
  fi
  [ "${REGENERATE_CLIENTS:-0}" = "1" ] && rm -f "$OBFS_ENV" 2>/dev/null

  # Load any persisted values into FILE_* (do not clobber user env).
  local k v
  if [ -f "$OBFS_ENV" ]; then
    while IFS='=' read -r k v; do
      case "$k" in OBFS_*) eval "FILE_${k}=\$v" ;; esac
    done < "$OBFS_ENV"
  fi

  _obfs_resolve OBFS_JC   "rand_int 4 12"
  _obfs_resolve OBFS_JMIN "rand_int 8 32"
  _obfs_resolve OBFS_JMAX "rand_int $(( ${OBFS_JMIN:-8} + 32 )) $(( ${OBFS_JMIN:-8} + 96 ))"
  _obfs_resolve OBFS_S1   "rand_int 15 150"
  _obfs_resolve OBFS_S2   "_gen_s2"
  _resolve_h OBFS_H1 ""
  _resolve_h OBFS_H2 "${OBFS_H1}"
  _resolve_h OBFS_H3 "${OBFS_H1} ${OBFS_H2}"
  _resolve_h OBFS_H4 "${OBFS_H1} ${OBFS_H2} ${OBFS_H3}"

  { for v in OBFS_JC OBFS_JMIN OBFS_JMAX OBFS_S1 OBFS_S2 OBFS_H1 OBFS_H2 OBFS_H3 OBFS_H4; do
      eval "printf '%s=%s\n' \"$v\" \"\${$v}\""
    done
  } > "$OBFS_ENV"
  chmod 600 "$OBFS_ENV" 2>/dev/null || true
}

_obfs_resolve() { # name gen_expr
  local name="$1" genexpr="$2" cur file
  eval "cur=\${$name:-}"
  eval "file=\${FILE_$name:-}"
  if   [ -n "$cur" ];  then :
  elif [ -n "$file" ]; then cur="$file"
  else cur="$(eval "$genexpr")"; fi
  eval "$name=\$cur"
  eval "export $name"
}

_gen_s2() { # S2 must differ from S1 and from S1+56
  local s
  while :; do
    s="$(rand_int 15 150)"
    if [ "$s" -ne "${OBFS_S1}" ] && [ "$s" -ne "$(( OBFS_S1 + 56 ))" ]; then
      echo "$s"; return
    fi
  done
}

_resolve_h() { # name existing-list
  local name="$1" existing="$2" cur file h
  eval "cur=\${$name:-}"
  eval "file=\${FILE_$name:-}"
  if   [ -n "$cur" ];  then :
  elif [ -n "$file" ]; then cur="$file"
  else
    while :; do
      h="$(rand_int 5 2147483647)"
      case " $existing " in *" $h "*) ;; *) cur="$h"; break ;; esac
    done
  fi
  eval "$name=\$cur"
  eval "export $name"
}

# --- server key ---------------------------------------------------------------
ensure_server_keys() {
  mkdir -p "$DATA_DIR"
  local _om; _om="$(umask)"; umask 077
  if [ ! -f "$SERVER_PRIV" ]; then
    log_info "Generating server keypair (persisted in /data)"
    _gen_privkey > "$SERVER_PRIV"
    chmod 600 "$SERVER_PRIV"
    _pubkey < "$SERVER_PRIV" > "$SERVER_PUB"
  fi
  umask "$_om"
  SERVER_PUBKEY="$(cat "$SERVER_PUB")"
  export SERVER_PUBKEY
}

# --- clients ------------------------------------------------------------------
# Reconciles CLIENTS_TSV -> per-client keys + assigned IPs -> RESOLVED_TSV.
# Idempotent: existing client keys are reused unless REGENERATE_CLIENTS=1.
resolve_clients() {
  mkdir -p "$CLIENT_KEY_DIR"
  local _om; _om="$(umask)"; umask 077
  : > "$RESOLVED_TSV"
  local TAB; TAB="$(printf '\t')"

  local name addr aips used current=" "
  used=" $(cidr_host "$VPN_SUBNET" 1) "   # reserve server .1

  # Pass 1: reserve all fixed addresses + record current names.
  while IFS="$TAB" read -r name addr aips || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    current="${current}${name} "
    [ -n "$addr" ] && used="${used}${addr} "
  done < "$CLIENTS_TSV"

  # Pass 2: ensure keys + assign addresses + emit resolved rows.
  local next_idx=2 cdir ip pub caips
  while IFS="$TAB" read -r name addr aips || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    cdir="${CLIENT_KEY_DIR}/${name}"
    mkdir -p "$cdir"
    if [ "${REGENERATE_CLIENTS:-0}" = "1" ]; then
      rm -f "$cdir/private.key" "$cdir/public.key" "$cdir/preshared.key"
    fi
    if [ ! -f "$cdir/private.key" ]; then
      log_info "Generating keys for client '${name}'"
      _gen_privkey > "$cdir/private.key"; chmod 600 "$cdir/private.key"
      _pubkey < "$cdir/private.key" > "$cdir/public.key"
      _genpsk > "$cdir/preshared.key"; chmod 600 "$cdir/preshared.key"
    fi
    ip="$addr"
    if [ -z "$ip" ]; then
      while :; do
        ip="$(cidr_host "$VPN_SUBNET" "$next_idx")"
        next_idx=$(( next_idx + 1 ))
        case "$used" in *" $ip "*) ;; *) used="${used}${ip} "; break ;; esac
      done
    fi
    pub="$(cat "$cdir/public.key")"
    caips="${aips:-$ALLOWED_IPS}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$ip" "$pub" "$cdir/private.key" "$cdir/preshared.key" "$caips" \
      >> "$RESOLVED_TSV"
  done < "$CLIENTS_TSV"

  # Archive key dirs for clients no longer listed (keys kept, never deleted).
  local d base
  for d in "$CLIENT_KEY_DIR"/*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    [ "$base" = ".archived" ] && continue
    case "$current" in
      *" $base "*) ;;
      *) mkdir -p "$CLIENT_KEY_DIR/.archived"
         mv "$d" "$CLIENT_KEY_DIR/.archived/${base}.$(rand_int 1000 9999)" 2>/dev/null || true
         log_info "Archived removed client '${base}'" ;;
    esac
  done
  umask "$_om"
}
