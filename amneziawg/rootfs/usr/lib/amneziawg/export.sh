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
