#!/usr/bin/env bash
# render.sh — render the server interface config and per-client configs.
# Requires common.sh + keys.sh outputs (RESOLVED_TSV, SERVER_PRIV/PUB, OBFS_*,
# SERVER_PUBKEY). Configs that contain private keys are written mode 600 and are
# never logged.

# Emit AmneziaWG obfuscation lines into the current [Interface] block, if enabled.
_obfs_block() {
  [ "${OBFS_ENABLED:-1}" = "1" ] || return 0
  printf 'Jc = %s\n'   "${OBFS_JC}"
  printf 'Jmin = %s\n' "${OBFS_JMIN}"
  printf 'Jmax = %s\n' "${OBFS_JMAX}"
  printf 'S1 = %s\n'   "${OBFS_S1}"
  printf 'S2 = %s\n'   "${OBFS_S2}"
  printf 'H1 = %s\n'   "${OBFS_H1}"
  printf 'H2 = %s\n'   "${OBFS_H2}"
  printf 'H3 = %s\n'   "${OBFS_H3}"
  printf 'H4 = %s\n'   "${OBFS_H4}"
}

render_server_conf() {
  local prefix server_ip TAB name ip pub priv psk aips _om
  prefix="$(cidr_prefix "$VPN_SUBNET")"
  server_ip="$(cidr_host "$VPN_SUBNET" 1)"
  TAB="$(printf '\t')"
  _om="$(umask)"; umask 077
  {
    echo "# Managed by the AmneziaWG add-on — regenerated on each start. Do not edit."
    echo "[Interface]"
    echo "Address = ${server_ip}/${prefix}"
    echo "ListenPort = ${SERVER_PORT}"
    echo "PrivateKey = $(cat "$SERVER_PRIV")"
    [ -n "${MTU:-}" ] && echo "MTU = ${MTU}"
    _obfs_block
    while IFS="$TAB" read -r name ip pub priv psk aips || [ -n "$name" ]; do
      [ -z "$name" ] && continue
      echo ""
      echo "[Peer]"
      echo "# ${name}"
      echo "PublicKey = ${pub}"
      echo "PresharedKey = $(cat "$psk")"
      echo "AllowedIPs = ${ip}/32"
    done < "$RESOLVED_TSV"
  } > "$SERVER_CONF"
  chmod 600 "$SERVER_CONF"
  umask "$_om"
}

# render_client_conf NAME -> stdout. Returns non-zero if NAME is unknown.
render_client_conf() {
  local want="$1" TAB name ip pub priv psk aips found=0
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r name ip pub priv psk aips || [ -n "$name" ]; do
    [ "$name" = "$want" ] || continue
    found=1
    echo "[Interface]"
    echo "PrivateKey = $(cat "$priv")"
    echo "Address = ${ip}/32"
    [ -n "${CLIENT_DNS:-}" ] && echo "DNS = $(echo "${CLIENT_DNS}" | tr ' ' ',')"
    [ -n "${MTU:-}" ] && echo "MTU = ${MTU}"
    _obfs_block
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${SERVER_PUBKEY}"
    echo "PresharedKey = $(cat "$psk")"
    echo "Endpoint = ${ENDPOINT_HOST}:${SERVER_PORT}"
    echo "AllowedIPs = ${aips}"
    if [ "${PERSISTENT_KEEPALIVE:-0}" -gt 0 ] 2>/dev/null; then
      echo "PersistentKeepalive = ${PERSISTENT_KEEPALIVE}"
    fi
    break
  done < "$RESOLVED_TSV"
  [ "$found" = "1" ]
}
