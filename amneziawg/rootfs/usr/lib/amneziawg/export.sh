#!/usr/bin/env bash
# export.sh — deliver client configs: write <name>.conf + <name>.png (QR) to the
# export dir, and optionally print a scannable QR to the add-on log.
# Requires common.sh + render.sh. Config CONTENTS are never logged as plain text.

export_clients() {
  mkdir -p "$EXPORT_DIR"
  chmod 700 "$EXPORT_DIR" 2>/dev/null || true

  local TAB name ip pub conf _om
  TAB="$(printf '\t')"
  _om="$(umask)"; umask 077

  # Columns: name ip pubkey privkey_file psk_file allowed_ips — last 3 unused here.
  while IFS="$TAB" read -r name ip pub _ _ _ || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    conf="${EXPORT_DIR}/${name}.conf"
    render_client_conf "$name" > "$conf"
    chmod 600 "$conf"
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t png -o "${EXPORT_DIR}/${name}.png" < "$conf" 2>/dev/null \
        || log_warn "qrencode PNG generation failed for client '${name}'"
    fi
    log_info "Client '${name}': ip=${ip} pubkey=$(key_fingerprint "$pub")… -> ${conf}"
  done < "$RESOLVED_TSV"
  umask "$_om"

  # Optional: print a scannable QR per client to the log.
  if command -v qrencode >/dev/null 2>&1 && [ "${QR_IN_LOG:-1}" = "1" ]; then
    log_warn "QR codes below encode the FULL client config incl. its private key — do not share raw add-on logs."
    while IFS="$TAB" read -r name _ _ _ _ _ || [ -n "$name" ]; do
      [ -z "$name" ] && continue
      log_info "QR for client '${name}' (scan with the Amnezia app / awg):"
      render_client_conf "$name" | qrencode -t ANSIUTF8 2>/dev/null || true
    done < "$RESOLVED_TSV"
  fi
}

# export_keys — write individual key files for server + clients to KEY_EXPORT_DIR,
# then a portable bundle. Gated by the caller (KEY_EXPORT_ENABLED). Secrets stay 600.
export_keys() {
  local _om; _om="$(umask)"; umask 077
  mkdir -p "${KEY_EXPORT_DIR}/server" "${KEY_EXPORT_DIR}/clients"
  chmod 700 "$KEY_EXPORT_DIR" "${KEY_EXPORT_DIR}/server" "${KEY_EXPORT_DIR}/clients" 2>/dev/null || true

  cp "$SERVER_PRIV" "${KEY_EXPORT_DIR}/server/private.key"
  cp "$SERVER_PUB"  "${KEY_EXPORT_DIR}/server/public.key"
  chmod 600 "${KEY_EXPORT_DIR}/server/private.key" "${KEY_EXPORT_DIR}/server/public.key"

  local TAB name d
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r name _ _ _ _ _ || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    d="${KEY_EXPORT_DIR}/clients/${name}"
    mkdir -p "$d"; chmod 700 "$d"
    cp "${CLIENT_KEY_DIR}/${name}/private.key"   "$d/private.key"
    cp "${CLIENT_KEY_DIR}/${name}/public.key"    "$d/public.key"
    cp "${CLIENT_KEY_DIR}/${name}/preshared.key" "$d/preshared.key"
    chmod 600 "$d"/*.key
  done < "$RESOLVED_TSV"
  umask "$_om"

  write_bundle
  log_warn "key_export.enabled is ON — keys written under ${KEY_EXPORT_DIR} and a bundle to ${BUNDLE_OUT}. Set key_export.enabled back to false, then protect or delete these files."
}

# write_bundle — assemble the JSON key bundle and write BUNDLE_OUT, encrypting with
# KEY_EXPORT_PASSPHRASE when set. Bundle = server priv + obfuscation + per-client {name,priv,psk}.
write_bundle() {
  local TAB name tmp clients_json _om
  TAB="$(printf '\t')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/awg-bundle.XXXXXX")"
  clients_json="[]"
  while IFS="$TAB" read -r name _ _ _ _ _ || [ -n "$name" ]; do
    [ -z "$name" ] && continue
    clients_json="$(printf '%s' "$clients_json" | jq \
      --arg n   "$name" \
      --arg pk  "$(cat "${CLIENT_KEY_DIR}/${name}/private.key")" \
      --arg psk "$(cat "${CLIENT_KEY_DIR}/${name}/preshared.key")" \
      '. + [{name:$n, private_key:$pk, preshared_key:$psk}]')"
  done < "$RESOLVED_TSV"

  jq -n \
    --arg spk  "$(cat "$SERVER_PRIV")" \
    --argjson clients "$clients_json" \
    --arg jc "${OBFS_JC:-}"   --arg jmin "${OBFS_JMIN:-}" --arg jmax "${OBFS_JMAX:-}" \
    --arg s1 "${OBFS_S1:-}"   --arg s2 "${OBFS_S2:-}" \
    --arg h1 "${OBFS_H1:-}"   --arg h2 "${OBFS_H2:-}" \
    --arg h3 "${OBFS_H3:-}"   --arg h4 "${OBFS_H4:-}" \
    '{format:"amneziawg-keybundle", version:1,
      server:{private_key:$spk},
      obfuscation:{jc:$jc,jmin:$jmin,jmax:$jmax,s1:$s1,s2:$s2,h1:$h1,h2:$h2,h3:$h3,h4:$h4},
      clients:$clients}' > "$tmp"

  _om="$(umask)"; umask 077
  if [ -n "${KEY_EXPORT_PASSPHRASE:-}" ]; then
    _encrypt_bundle "$tmp" "$BUNDLE_OUT" "$KEY_EXPORT_PASSPHRASE"
  else
    cp "$tmp" "$BUNDLE_OUT"
  fi
  chmod 600 "$BUNDLE_OUT"
  umask "$_om"
  rm -f "$tmp"
  log_info "Wrote key bundle ($(grep -c . "$RESOLVED_TSV") client(s)) -> ${BUNDLE_OUT}$([ -n "${KEY_EXPORT_PASSPHRASE:-}" ] && printf ' (encrypted)')"
}

# _encrypt_bundle IN OUT PASS — AES-256/PBKDF2; passphrase via env, never argv.
_encrypt_bundle() {
  BUNDLE_PASS="$3" openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
    -pass env:BUNDLE_PASS -in "$1" -out "$2"
}
