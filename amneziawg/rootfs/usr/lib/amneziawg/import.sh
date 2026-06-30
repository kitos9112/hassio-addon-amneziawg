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

# _is_encrypted_bundle PATH -> 0 if the file starts with openssl's 'Salted__' magic.
_is_encrypted_bundle() {
  [ "$(head -c 8 "$1" 2>/dev/null)" = "Salted__" ]
}

# _decrypt_bundle IN OUT -> decrypt to OUT using BUNDLE_PASS from the environment
# (caller sets it, keeping the passphrase off every process argv); non-zero on
# wrong passphrase / corruption.
_decrypt_bundle() {
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    -pass env:BUNDLE_PASS -in "$1" -out "$2"
}

# restore_bundle — import keys from BUNDLE_IN into /data (fill-empty unless overwrite).
# Auto-detects encryption; seeds server priv, obfuscation.env, and per-client priv/psk.
restore_bundle() {
  [ "${KEY_IMPORT_RESTORE:-0}" = "1" ] || return 0
  [ -f "$BUNDLE_IN" ] || { log_error "key_import.restore is on but ${BUNDLE_IN} is missing."; return 1; }

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/awg-restore.XXXXXX")"
  if _is_encrypted_bundle "$BUNDLE_IN"; then
    if [ -z "${KEY_IMPORT_PASSPHRASE:-}" ]; then
      rm -f "$tmp"; log_error "Restore bundle is encrypted but key_import.passphrase is empty."; return 1
    fi
    if ! BUNDLE_PASS="$KEY_IMPORT_PASSPHRASE" _decrypt_bundle "$BUNDLE_IN" "$tmp" 2>/dev/null; then
      rm -f "$tmp"; log_error "Restore failed: wrong passphrase or corrupt bundle."; return 1
    fi
  else
    cp "$BUNDLE_IN" "$tmp"
  fi

  if ! jq -e '.format=="amneziawg-keybundle"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; log_error "Restore failed: not an AmneziaWG key bundle."; return 1
  fi

  mkdir -p "$DATA_DIR" "$CLIENT_KEY_DIR"

  local spk; spk="$(jq -r '.server.private_key // ""' "$tmp")"
  if [ -n "$spk" ]; then
    _seed_key "$SERVER_PRIV" "$spk" "server private key (restore)" && rm -f "$SERVER_PUB"
  fi

  # obfuscation.env (fill-empty unless overwrite)
  if [ ! -f "$OBFS_ENV" ] || [ "${KEY_IMPORT_OVERWRITE:-0}" = "1" ]; then
    local jc k v _om
    jc="$(jq -r '.obfuscation.jc // ""' "$tmp")"
    if [ -n "$jc" ]; then
      _om="$(umask)"; umask 077
      {
        for k in jc jmin jmax s1 s2 h1 h2 h3 h4; do
          v="$(jq -r ".obfuscation.${k} // \"\"" "$tmp")"
          [ -n "$v" ] && printf 'OBFS_%s=%s\n' "$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" "$v"
        done
      } > "$OBFS_ENV"
      chmod 600 "$OBFS_ENV"
      umask "$_om"
      log_info "Restore: seeded obfuscation parameters."
    fi
  fi

  # clients
  local count i name pk psk
  count="$(jq '.clients | length' "$tmp")"
  i=0
  while [ "$i" -lt "$count" ]; do
    name="$(jq -r ".clients[$i].name" "$tmp")"
    pk="$(jq  -r ".clients[$i].private_key // \"\"" "$tmp")"
    psk="$(jq -r ".clients[$i].preshared_key // \"\"" "$tmp")"
    if [ -n "$pk" ]; then
      _seed_key "${CLIENT_KEY_DIR}/${name}/private.key" "$pk" "client '${name}' private key (restore)" \
        && rm -f "${CLIENT_KEY_DIR}/${name}/public.key"
    fi
    [ -n "$psk" ] && _seed_key "${CLIENT_KEY_DIR}/${name}/preshared.key" "$psk" "client '${name}' preshared key (restore)"
    i=$((i + 1))
  done

  rm -f "$tmp"
  log_warn "key_import.restore is ON — restored keys from ${BUNDLE_IN}. Set key_import.restore back to false."
  return 0
}
