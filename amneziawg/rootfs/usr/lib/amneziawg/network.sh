#!/usr/bin/env bash
# network.sh — IPv4 forwarding + NAT/masquerade for the AmneziaWG exit node.
# Requires common.sh. All rules carry a comment tag so teardown removes exactly
# the rules this add-on created and nothing else.

AWG_FW_TAG="amneziawg-addon"

_detect_wan() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Remove our tagged rules for a given WAN iface + subnet (idempotent).
_nat_remove() { # wan subnet
  local wan="$1" subnet="$2"
  iptables -t nat -D POSTROUTING -s "$subnet" -o "$wan" \
    -m comment --comment "$AWG_FW_TAG" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$IFACE" -s "$subnet" \
    -m comment --comment "$AWG_FW_TAG" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$IFACE" -d "$subnet" \
    -m state --state RELATED,ESTABLISHED \
    -m comment --comment "$AWG_FW_TAG" -j ACCEPT 2>/dev/null || true
}

nat_up() {
  if [ "${ENABLE_NAT:-1}" != "1" ]; then
    log_info "NAT disabled (enable_nat=false); not touching firewall/forwarding."
    return 0
  fi

  local wan prev_forward forward_ok
  wan="$(_detect_wan)"
  if [ -z "$wan" ]; then
    log_error "Could not detect a host WAN interface (no default route)."
    return 1
  fi

  prev_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    forward_ok=1
  elif [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
    forward_ok=1
  else
    forward_ok=0
    log_warn "Could not enable net.ipv4.ip_forward — client traffic will not route until forwarding is on (needs NET_ADMIN on the host)."
  fi

  # Clear any stale rules first (e.g. unclean previous shutdown).
  _nat_remove "$wan" "$VPN_SUBNET"

  iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$wan" \
    -m comment --comment "$AWG_FW_TAG" -j MASQUERADE
  # Insert FORWARD accepts at the top so a restrictive default policy/earlier
  # DROP cannot pre-empt the exit-node traffic.
  iptables -I FORWARD 1 -i "$IFACE" -s "$VPN_SUBNET" \
    -m comment --comment "$AWG_FW_TAG" -j ACCEPT
  iptables -I FORWARD 1 -o "$IFACE" -d "$VPN_SUBNET" \
    -m state --state RELATED,ESTABLISHED \
    -m comment --comment "$AWG_FW_TAG" -j ACCEPT

  {
    echo "WAN_IFACE=${wan}"
    echo "NAT_SUBNET=${VPN_SUBNET}"
    echo "PREV_IP_FORWARD=${prev_forward}"
  } > "$RUNTIME_STATE"

  log_info "NAT on: ${VPN_SUBNET} masqueraded via '${wan}'."
  [ "$forward_ok" = "1" ] && log_info "IPv4 forwarding active."
  return 0
}

nat_down() {
  local wan subnet prev
  if [ -f "$RUNTIME_STATE" ]; then
    # shellcheck disable=SC1090
    . "$RUNTIME_STATE"
    wan="${WAN_IFACE:-}"
    subnet="${NAT_SUBNET:-${VPN_SUBNET:-}}"
    prev="${PREV_IP_FORWARD:-0}"
  else
    wan="$(_detect_wan)"
    subnet="${VPN_SUBNET:-}"
    prev="0"
  fi

  if [ -n "$wan" ] && [ -n "$subnet" ]; then
    _nat_remove "$wan" "$subnet"
  fi
  sysctl -w net.ipv4.ip_forward="${prev:-0}" >/dev/null 2>&1 || true
  rm -f "$RUNTIME_STATE" 2>/dev/null || true
  log_info "NAT rules removed; IPv4 forwarding restored to ${prev:-0}."
}
