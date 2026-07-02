#!/usr/bin/env bash
# validate.sh — configuration validation.
# validate_all returns non-zero (logging the first problem) when the config is
# unusable. Never logs secrets. Requires common.sh to be sourced first.

validate_all() {
  local cidr

  # --- endpoint -------------------------------------------------------------
  if [ -z "${ENDPOINT_HOST:-}" ]; then
    log_error "endpoint_host is required (your public IP or DDNS hostname)."
    return 1
  fi
  if ! printf '%s' "${ENDPOINT_HOST}" | grep -qE '^[A-Za-z0-9._:-]+$'; then
    log_error "endpoint_host '${ENDPOINT_HOST}' has invalid characters (allowed: letters, digits, . _ : -)."
    return 1
  fi

  # --- vpn_subnet (IPv4 only — used for host arithmetic) --------------------
  if ! is_valid_cidr "${VPN_SUBNET:-}"; then
    log_error "vpn_subnet '${VPN_SUBNET:-}' is not a valid CIDR."
    return 1
  fi
  case "${VPN_SUBNET}" in
    *:*) log_error "vpn_subnet must be IPv4 (got '${VPN_SUBNET}')."; return 1 ;;
  esac
  if [ "${VPN_SUBNET#*/}" -gt 30 ]; then
    log_error "vpn_subnet '${VPN_SUBNET}' is too small; use /30 or larger (need a server plus at least one client)."
    return 1
  fi

  # --- allowed_ips (comma/space separated CIDR list) ------------------------
  for cidr in $(echo "${ALLOWED_IPS:-}" | tr ',' ' '); do
    [ -z "$cidr" ] && continue
    if ! is_valid_cidr "$cidr"; then
      log_error "allowed_ips entry '$cidr' is not a valid CIDR."
      return 1
    fi
  done

  # --- client_dns (each entry must be a valid IP) ---------------------------
  local dns
  for dns in ${CLIENT_DNS:-}; do
    [ -z "$dns" ] && continue
    if ! is_valid_ipv4 "$dns" && ! printf '%s' "$dns" | grep -qE '^[0-9a-fA-F:]+$'; then
      log_error "client_dns entry '$dns' is not a valid IP address."
      return 1
    fi
  done

  # --- server_port ----------------------------------------------------------
  if ! [[ "${SERVER_PORT:-}" =~ ^[0-9]+$ ]] \
     || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
    log_error "server_port '${SERVER_PORT:-}' must be 1-65535."
    return 1
  fi

  # --- endpoint_port (optional external/advertised port) --------------------
  if [ -n "${ENDPOINT_PORT:-}" ]; then
    if ! [[ "${ENDPOINT_PORT}" =~ ^[0-9]+$ ]] \
       || [ "${ENDPOINT_PORT}" -lt 1 ] || [ "${ENDPOINT_PORT}" -gt 65535 ]; then
      log_error "endpoint_port '${ENDPOINT_PORT}' must be 1-65535."
      return 1
    fi
  fi

  # --- clients --------------------------------------------------------------
  local capacity server_ip count=0 name addr aips
  local seen_names=" " seen_addrs=" "
  capacity="$(cidr_capacity "$VPN_SUBNET")"
  server_ip="$(cidr_host "$VPN_SUBNET" 1)"
  if [ -f "${CLIENTS_TSV}" ]; then
    while IFS="$(printf '\t')" read -r name addr aips || [ -n "$name" ]; do
      [ -z "$name" ] && continue
      count=$((count + 1))
      case "$seen_names" in
        *" $name "*) log_error "duplicate client name '$name'."; return 1 ;;
      esac
      seen_names="${seen_names}${name} "
      if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$'; then
        log_error "client name '$name' has invalid characters (allowed: a-z A-Z 0-9 _ -, max 32)."
        return 1
      fi
      if [ -n "$addr" ]; then
        if ! is_valid_ipv4 "$addr"; then
          log_error "client '$name' address '$addr' is not a valid IPv4."
          return 1
        fi
        if ! cidr_contains "$VPN_SUBNET" "$addr"; then
          log_error "client '$name' address '$addr' is outside vpn_subnet '$VPN_SUBNET'."
          return 1
        fi
        if [ "$addr" = "$server_ip" ]; then
          log_error "client '$name' address '$addr' collides with the server address."
          return 1
        fi
        if [ "$addr" = "$(cidr_host "$VPN_SUBNET" 0)" ] || [ "$addr" = "$(cidr_broadcast "$VPN_SUBNET")" ]; then
          log_error "client '$name' address '$addr' is the network or broadcast address."
          return 1
        fi
        case "$seen_addrs" in
          *" $addr "*) log_error "duplicate client address '$addr'."; return 1 ;;
        esac
        seen_addrs="${seen_addrs}${addr} "
      fi
      if [ -n "$aips" ]; then
        for cidr in $(echo "$aips" | tr ',' ' '); do
          [ -z "$cidr" ] && continue
          if ! is_valid_cidr "$cidr"; then
            log_error "client '$name' allowed_ips entry '$cidr' is invalid."
            return 1
          fi
        done
      fi
    done < "${CLIENTS_TSV}"
  fi
  if [ "$count" -gt "$capacity" ]; then
    log_error "too many clients ($count) for subnet $VPN_SUBNET (capacity $capacity)."
    return 1
  fi

  # --- obfuscation constraints (only when values are explicitly provided) ----
  if [ "${OBFS_ENABLED:-1}" = "1" ]; then
    local ov oval
    for ov in OBFS_JC OBFS_JMIN OBFS_JMAX OBFS_S1 OBFS_S2 OBFS_H1 OBFS_H2 OBFS_H3 OBFS_H4; do
      eval "oval=\${$ov:-}"
      if [ -n "$oval" ] && ! printf '%s' "$oval" | grep -qE '^[0-9]+$'; then
        log_error "obfuscation ${ov} ('${oval}') must be a non-negative integer."
        return 1
      fi
    done
    if [ -n "${OBFS_JMIN:-}" ] && [ -n "${OBFS_JMAX:-}" ] \
       && [ "${OBFS_JMAX}" -le "${OBFS_JMIN}" ]; then
      log_error "obfuscation jmax (${OBFS_JMAX}) must be greater than jmin (${OBFS_JMIN})."
      return 1
    fi
    if [ -n "${OBFS_S1:-}" ] && [ -n "${OBFS_S2:-}" ]; then
      if [ "${OBFS_S1}" = "${OBFS_S2}" ]; then
        log_error "obfuscation s1 and s2 must differ."
        return 1
      fi
      if [ "${OBFS_S2}" -eq "$(( OBFS_S1 + 56 ))" ]; then
        log_error "obfuscation s2 must not equal s1 + 56 (handshake size clash)."
        return 1
      fi
    fi
    local hs=" " h
    for h in "${OBFS_H1:-}" "${OBFS_H2:-}" "${OBFS_H3:-}" "${OBFS_H4:-}"; do
      [ -z "$h" ] && continue
      if [ "$h" -ge 1 ] 2>/dev/null && [ "$h" -le 4 ]; then
        log_error "obfuscation header value '$h' must not be in 1..4."
        return 1
      fi
      case "$hs" in
        *" $h "*) log_error "obfuscation header values must be distinct (duplicate '$h')."; return 1 ;;
      esac
      hs="${hs}${h} "
    done
  fi

  # --- kernel / TUN ---------------------------------------------------------
  if [ "${SKIP_TUN_CHECK:-0}" != "1" ]; then
    if [ ! -c /dev/net/tun ]; then
      log_error "/dev/net/tun is missing — the add-on needs devices:[/dev/net/tun] + NET_ADMIN."
      return 1
    fi
  fi

  # --- key import / restore (fail fast; never log the key value) -------------
  # regenerate_clients is mutually exclusive with key import/restore ------
  if [ "${REGENERATE_CLIENTS:-0}" = "1" ]; then
    if [ "${KEY_IMPORT_RESTORE:-0}" = "1" ] || [ -n "${IMPORT_SERVER_KEY:-}" ] \
       || { [ -f "${CLIENT_IMPORT_TSV:-/nonexistent}" ] && [ -s "${CLIENT_IMPORT_TSV}" ]; }; then
      log_error "regenerate_clients cannot be combined with key import or restore — regeneration would discard the imported keys. Disable one of them."
      return 1
    fi
  fi
  if [ -n "${IMPORT_SERVER_KEY:-}" ] && ! is_valid_wg_key "${IMPORT_SERVER_KEY}"; then
    log_error "server_private_key is not a valid WireGuard key (44-char base64)."
    return 1
  fi
  if [ -f "${CLIENT_IMPORT_TSV:-/nonexistent}" ]; then
    local _itab iname ipriv ipsk
    _itab="$(printf '\t')"
    while IFS="$_itab" read -r iname ipriv ipsk || [ -n "$iname" ]; do
      [ -z "$iname" ] && continue
      if [ -n "$ipriv" ] && ! is_valid_wg_key "$ipriv"; then
        log_error "client '${iname}' private_key is not a valid WireGuard key."
        return 1
      fi
      if [ -n "$ipsk" ] && ! is_valid_wg_key "$ipsk"; then
        log_error "client '${iname}' preshared_key is not a valid WireGuard key."
        return 1
      fi
    done < "${CLIENT_IMPORT_TSV}"
  fi
  if [ "${KEY_IMPORT_RESTORE:-0}" = "1" ]; then
    if [ ! -f "${BUNDLE_IN:-/nonexistent}" ]; then
      log_error "key_import.restore is on but ${BUNDLE_IN} is missing — place the bundle there first."
      return 1
    fi
    if [ "$(head -c 8 "${BUNDLE_IN}" 2>/dev/null)" = "Salted__" ] && [ -z "${KEY_IMPORT_PASSPHRASE:-}" ]; then
      log_error "Restore bundle is encrypted but key_import.passphrase is empty."
      return 1
    fi
  fi

  return 0
}
