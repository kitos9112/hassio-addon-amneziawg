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

  # --- vpn_subnet (IPv4 only — used for host arithmetic) --------------------
  if ! is_valid_cidr "${VPN_SUBNET:-}"; then
    log_error "vpn_subnet '${VPN_SUBNET:-}' is not a valid CIDR."
    return 1
  fi
  case "${VPN_SUBNET}" in
    *:*) log_error "vpn_subnet must be IPv4 (got '${VPN_SUBNET}')."; return 1 ;;
  esac

  # --- allowed_ips (comma/space separated CIDR list) ------------------------
  for cidr in $(echo "${ALLOWED_IPS:-}" | tr ',' ' '); do
    [ -z "$cidr" ] && continue
    if ! is_valid_cidr "$cidr"; then
      log_error "allowed_ips entry '$cidr' is not a valid CIDR."
      return 1
    fi
  done

  # --- server_port ----------------------------------------------------------
  if ! [[ "${SERVER_PORT:-}" =~ ^[0-9]+$ ]] \
     || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
    log_error "server_port '${SERVER_PORT:-}' must be 1-65535."
    return 1
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
      if ! printf '%s' "$name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$'; then
        log_error "client name '$name' has invalid characters (allowed: a-z A-Z 0-9 -, max 32)."
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

  return 0
}
