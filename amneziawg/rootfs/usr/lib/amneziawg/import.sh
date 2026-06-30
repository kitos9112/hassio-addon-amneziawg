#!/usr/bin/env bash
# import.sh — bring key material IN: paste-in server/client keys and bundle restore.
# Pre-seeds /data so the idempotent generators in keys.sh reuse imported keys.
# Fill-empty by default; KEY_IMPORT_OVERWRITE=1 replaces. Never logs key material.
# Requires common.sh (+ keys.sh for derivation downstream).

# _seed_key DEST VALUE LABEL -> 0 wrote, 1 skipped (exists, overwrite off), 2 invalid.
_seed_key() {
  local dest="$1" val="$2" label="$3" _om
  [ -n "$val" ] || return 1
  if ! is_valid_wg_key "$val"; then
    log_error "Import: ${label} is not a valid key — ignoring."
    return 2
  fi
  if [ -f "$dest" ] && [ "${KEY_IMPORT_OVERWRITE:-0}" != "1" ]; then
    if [ "$(cat "$dest")" != "$val" ]; then
      log_warn "Import: ${label} already exists and overwrite=false — keeping existing key."
    fi
    return 1
  fi
  _om="$(umask)"; umask 077
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$val" > "$dest"
  chmod 600 "$dest"
  umask "$_om"
  log_info "Import: ${label} set (fp $(key_fingerprint "$val")…)"
  return 0
}

# import_server_key — pre-seed SERVER_PRIV from IMPORT_SERVER_KEY; drop stale pub.
import_server_key() {
  [ -n "${IMPORT_SERVER_KEY:-}" ] || return 0
  if _seed_key "$SERVER_PRIV" "$IMPORT_SERVER_KEY" "server private key"; then
    rm -f "$SERVER_PUB"   # force re-derivation from the imported private key
  fi
  return 0
}

# import_client_keys — pre-seed per-client keys from CLIENT_IMPORT_TSV
# (name<TAB>private_key<TAB>preshared_key). Public keys are derived later by resolve_clients.
import_client_keys() {
  [ -f "${CLIENT_IMPORT_TSV:-/nonexistent}" ] || return 0
  local TAB name priv psk cdir
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r name priv psk || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    cdir="${CLIENT_KEY_DIR}/${name}"
    if [ -n "$priv" ]; then
      if _seed_key "$cdir/private.key" "$priv" "client '${name}' private key"; then
        rm -f "$cdir/public.key"
      fi
    fi
    [ -n "$psk" ] && _seed_key "$cdir/preshared.key" "$psk" "client '${name}' preshared key"
  done < "$CLIENT_IMPORT_TSV"
  return 0
}
