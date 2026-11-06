#!/bin/sh
# Transparent proxy dataplane: REDIRECT (TCP) and TPROXY (TCP+UDP)

ss_fw_modules_ok() {
  # Returns 0 if TPROXY modules look usable
  lsmod 2>/dev/null | grep -q xt_TPROXY || modprobe xt_TPROXY 2>/dev/null || return 1
  lsmod 2>/dev/null | grep -q xt_socket || modprobe xt_socket 2>/dev/null || true
  return 0
}

ss_fw_detect_mode() {
  # Prefer configured proxy mode; fall back to REDIRECT if TPROXY unavailable
  local want="${SS_PROXY_MODE:-redirect}"
  case "${SS_MODE}" in
  proxy) echo proxy; return 0 ;;
  redirect) echo redirect; return 0 ;;
  tproxy) want=tproxy ;;
  esac
  if [ "$want" = "tproxy" ]; then
    if ss_fw_modules_ok; then
      echo tproxy
      return 0
    fi
    ss_warn "xt_TPROXY unavailable — falling back to REDIRECT"
    echo redirect
    return 0
  fi
  echo redirect
}

ss_fw_ipt() {
  # ss_fw_ipt <table> <args...> — always firmware iptables, never Entware-shadowed
  local tbl="$1"
  shift
  ss_iptables_init
  "$SS_IPTABLES" -w -t "$tbl" "$@" 2>/dev/null
}

ss_fw_ip6() {
  local tbl="$1"
  shift
  ss_iptables_init
  "$SS_IP6TABLES" -w -t "$tbl" "$@" 2>/dev/null || true
}

ss_fw_ensure_chain() {
  local tbl="$1"
  local chain="$2"
  ss_fw_ipt "$tbl" -N "$chain" 2>/dev/null || ss_fw_ipt "$tbl" -F "$chain"
  # Only touch ip6 nat if the table exists (many Merlin builds lack ip6table_nat)
  if [ "$tbl" = "nat" ]; then
    ss_iptables_init
    if "$SS_IP6TABLES" -w -t nat -L -n >/dev/null 2>&1; then
      ss_fw_ip6 "$tbl" -N "$chain" 2>/dev/null || ss_fw_ip6 "$tbl" -F "$chain"
    fi
  else
    ss_fw_ip6 "$tbl" -N "$chain" 2>/dev/null || ss_fw_ip6 "$tbl" -F "$chain"
  fi
}

ss_fw_link_chain() {
  # Append jump (xrayui pattern) — never -I 1, so Merlin's own PREROUTING stays intact
  local tbl="$1"
  local parent="$2"
  local chain="$3"
  if ! ss_fw_ipt "$tbl" -C "$parent" -j "$chain" 2>/dev/null; then
    ss_fw_ipt "$tbl" -A "$parent" -j "$chain"
  fi
  if [ "$tbl" = "nat" ]; then
    ss_iptables_init
    if "$SS_IP6TABLES" -w -t nat -L -n >/dev/null 2>&1; then
      if ! ss_fw_ip6 "$tbl" -C "$parent" -j "$chain" 2>/dev/null; then
        ss_fw_ip6 "$tbl" -A "$parent" -j "$chain"
      fi
    fi
  else
    if ! ss_fw_ip6 "$tbl" -C "$parent" -j "$chain" 2>/dev/null; then
      ss_fw_ip6 "$tbl" -A "$parent" -j "$chain"
    fi
  fi
}

ss_fw_unlink_chain() {
  local tbl="$1"
  local parent="$2"
  local chain="$3"
  local guard=0
  while ss_fw_ipt "$tbl" -C "$parent" -j "$chain" 2>/dev/null && [ "$guard" -lt 16 ]; do
    ss_fw_ipt "$tbl" -D "$parent" -j "$chain"
    guard=$((guard + 1))
  done
  guard=0
  while ss_fw_ip6 "$tbl" -C "$parent" -j "$chain" 2>/dev/null && [ "$guard" -lt 16 ]; do
    ss_fw_ip6 "$tbl" -D "$parent" -j "$chain"
    guard=$((guard + 1))
  done
}

ss_fw_exclude_wan_ifaces() {
  # Do not hijack packets arriving from WAN / PPPoE / LTE (xrayui pattern)
  local tbl="$1"
  local chain="$2"
  local wan_if
  for wan_if in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' |
    grep -E '^(ppp|pppoe|wan|wwan|lte|l2tp|tun|wg)[0-9]*' | sed 's/@.*//'); do
    [ -n "$wan_if" ] || continue
    ss_fw_ipt "$tbl" -C "$chain" -i "$wan_if" -j RETURN 2>/dev/null ||
      ss_fw_ipt "$tbl" -I "$chain" 1 -i "$wan_if" -j RETURN
  done
  # Common Merlin WAN ifnames from nvram (often eth0/vlanX — not matched above)
  for wan_if in "$(nvram get wan0_ifname 2>/dev/null)" "$(nvram get wan1_ifname 2>/dev/null)" \
    "$(nvram get wan0_gw_ifname 2>/dev/null)" "$(nvram get wan0_pppoe_ifname 2>/dev/null)"; do
    [ -n "$wan_if" ] || continue
    ss_fw_ipt "$tbl" -C "$chain" -i "$wan_if" -j RETURN 2>/dev/null ||
      ss_fw_ipt "$tbl" -I "$chain" 1 -i "$wan_if" -j RETURN
  done
}

ss_fw_exclude_safe_traffic() {
  # xrayui-aligned exclusions so transparent mode cannot break LAN/DHCP/VPN/port-forwards
  local tbl="$1"
  local chain="$2"
  local cidr rip doko

  # First: never process WAN ingress
  ss_fw_exclude_wan_ifaces "$tbl" "$chain"

  # Local/router traffic (packets to/from the router itself)
  ss_fw_ipt "$tbl" -C "$chain" -m addrtype --src-type LOCAL -j RETURN 2>/dev/null ||
    ss_fw_ipt "$tbl" -I "$chain" 1 -m addrtype --src-type LOCAL -j RETURN
  ss_fw_ipt "$tbl" -C "$chain" -m addrtype --dst-type LOCAL -j RETURN 2>/dev/null ||
    ss_fw_ipt "$tbl" -I "$chain" 1 -m addrtype --dst-type LOCAL -j RETURN

  # Private / reserved destinations stay direct
  for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 239.0.0.0/8 240.0.0.0/4; do
    ss_fw_ipt "$tbl" -A "$chain" -d "$cidr" -j RETURN
  done
  rip=$(ss_router_ip)
  [ -n "$rip" ] && ss_fw_ipt "$tbl" -A "$chain" -d "$rip" -j RETURN

  # Broadcast
  ss_fw_ipt "$tbl" -A "$chain" -m addrtype --dst-type BROADCAST -j RETURN 2>/dev/null || true

  # DHCP / NTP / IKE / WireGuard / GlobalProtect — never hijack (esp. TPROXY UDP)
  ss_fw_ipt "$tbl" -A "$chain" -p udp -m multiport --dports 67,68,123,500,4500,4501,51820 -j RETURN 2>/dev/null || true

  # Inbound port-forwards already DNATed by Merlin
  ss_fw_ipt "$tbl" -A "$chain" -m conntrack --ctstate DNAT -j RETURN 2>/dev/null || true

  # Do not re-hijack packets already aimed at our dokodemo ports
  doko="${SS_REDIRECT_PORT:-10811}"
  ss_fw_ipt "$tbl" -A "$chain" -p tcp --dport "$doko" -j RETURN 2>/dev/null || true
  doko="${SS_TPROXY_PORT:-10810}"
  ss_fw_ipt "$tbl" -A "$chain" -p tcp --dport "$doko" -j RETURN 2>/dev/null || true
  ss_fw_ipt "$tbl" -A "$chain" -p udp --dport "$doko" -j RETURN 2>/dev/null || true
}

# Back-compat alias
ss_fw_exclude_private() {
  ss_fw_exclude_safe_traffic "$@"
}

ss_firewall_is_configured() {
  local chain="$SS_FW_CHAIN"
  ss_iptables_init
  case "$(ss_fw_detect_mode)" in
  tproxy)
    "$SS_IPTABLES" -w -t mangle -L "$chain" -n >/dev/null 2>&1
    ;;
  redirect)
    "$SS_IPTABLES" -w -t nat -L "$chain" -n >/dev/null 2>&1
    ;;
  *)
    return 0
    ;;
  esac
}

ss_fw_exclude_endpoints() {
  # Anti-loop: exclude active StealthSurf node IPs
  local tbl="$1"
  local chain="$2"
  local ip
  if [ -f "$SS_ENDPOINTS_FILE" ]; then
    jq -r '.[] | .address // empty' "$SS_ENDPOINTS_FILE" 2>/dev/null | while read -r ip; do
      [ -z "$ip" ] && continue
      case "$ip" in
      *:* ) continue ;; # skip v6 literals in v4 rules
      *) ss_fw_ipt "$tbl" -A "$chain" -d "$ip" -j RETURN ;;
      esac
    done
  fi
}

ss_fw_apply_client_policies() {
  # Apply MAC bypass/redirect before catch-all. Returns whether any user rules exist.
  local tbl="$1"
  local chain="$2"
  local mode="$3" # redirect|tproxy
  local has_rules=0
  local has_catchall=0
  local rule_mode mac ports proto dport action

  [ -f "$SS_POLICIES_FILE" ] || {
    echo 0
    return 0
  }

  jq -c '.rules // [] | .[]' "$SS_POLICIES_FILE" 2>/dev/null | while read -r rule; do
    rule_mode=$(printf '%s' "$rule" | jq -r '.mode // empty')
    mac=$(printf '%s' "$rule" | jq -r '.mac // empty' | tr 'a-z' 'A-Z')
    ports=$(printf '%s' "$rule" | jq -r '.ports // empty')
    proto=$(printf '%s' "$rule" | jq -r '.proto // "tcp"')
    [ -n "$mac" ] || continue
    [ -n "$rule_mode" ] || continue

    case "$rule_mode" in
    bypass)
      if [ -n "$ports" ] && [ "$ports" != "null" ]; then
        for dport in $(printf '%s' "$ports" | tr ',' ' '); do
          ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p "$proto" --dport "$dport" -j RETURN
        done
      else
        ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -j RETURN
      fi
      ;;
    redirect)
      if [ -n "$ports" ] && [ "$ports" != "null" ]; then
        for dport in $(printf '%s' "$ports" | tr ',' ' '); do
          if [ "$mode" = "tproxy" ]; then
            ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p "$proto" --dport "$dport" \
              -j TPROXY --on-port "$SS_TPROXY_PORT" --tproxy-mark "${SS_TPROXY_MARK}/${SS_TPROXY_MASK}"
          else
            [ "$proto" = "tcp" ] && ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p tcp --dport "$dport" \
              -j REDIRECT --to-ports "$SS_REDIRECT_PORT"
          fi
        done
      else
        if [ "$mode" = "tproxy" ]; then
          ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p tcp \
            -j TPROXY --on-port "$SS_TPROXY_PORT" --tproxy-mark "${SS_TPROXY_MARK}/${SS_TPROXY_MASK}"
          ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p udp \
            -j TPROXY --on-port "$SS_TPROXY_PORT" --tproxy-mark "${SS_TPROXY_MARK}/${SS_TPROXY_MASK}"
        else
          ss_fw_ipt "$tbl" -A "$chain" -m mac --mac-source "$mac" -p tcp \
            -j REDIRECT --to-ports "$SS_REDIRECT_PORT"
        fi
      fi
      ;;
    esac
  done

  # Detect presence for caller semantics
  if jq -e '(.rules // []) | length > 0' "$SS_POLICIES_FILE" >/dev/null 2>&1; then
    has_rules=1
  fi
  if jq -e '(.rules // []) | any(.mode == "redirect" and ((.mac // "") == "" or .catchall == true))' "$SS_POLICIES_FILE" >/dev/null 2>&1; then
    has_catchall=1
  fi
  # Also treat explicit catchall flag / empty-mac redirect as catch-all
  if jq -e '(.catchall // false) == true' "$SS_POLICIES_FILE" >/dev/null 2>&1; then
    has_catchall=1
  fi
  echo "${has_rules}:${has_catchall}"
}

ss_fw_tcpmss_clamp() {
  # Clamp MSS on SYN to avoid PMTU blackholes through tunnels.
  # Mark with comment so cleanup can remove only our rule.
  if ! ss_fw_ipt mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "STEALTHSURF_TCPMSS" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    # Prefer commented rule; fall back without comment module
    ss_fw_ipt mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "STEALTHSURF_TCPMSS" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||
      ss_fw_ipt mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  fi
}

ss_fw_tcpmss_cleanup() {
  while ss_fw_ipt mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "STEALTHSURF_TCPMSS" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
    ss_fw_ipt mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "STEALTHSURF_TCPMSS" -j TCPMSS --clamp-mss-to-pmtu
  done
}

ss_configure_firewall_redirect() {
  local chain="$SS_FW_CHAIN"
  local port="$SS_REDIRECT_PORT"
  local policy_info has_rules has_catchall

  ss_activity "firewall.redirect" "port=$port chain=$chain"
  ss_fw_ensure_chain nat "$chain"
  ss_fw_exclude_private nat "$chain"
  ss_fw_exclude_endpoints nat "$chain"

  # DNS hijack optional
  case "$SS_DNS_MODE" in
  REDIRECT)
    ss_fw_ipt nat -A "$chain" -p udp --dport 53 -j REDIRECT --to-ports "$SS_DNS_PORT"
    ss_fw_ipt nat -A "$chain" -p tcp --dport 53 -j REDIRECT --to-ports "$SS_DNS_PORT"
    ;;
  BYPASS)
    ss_fw_ipt nat -A "$chain" -p udp --dport 53 -j RETURN
    ss_fw_ipt nat -A "$chain" -p tcp --dport 53 -j RETURN
    ;;
  esac

  policy_info=$(ss_fw_apply_client_policies nat "$chain" redirect)
  has_rules=${policy_info%%:*}
  has_catchall=${policy_info##*:}

  if [ "$has_rules" = "1" ] && [ "$has_catchall" != "1" ]; then
    ss_warn "Client policies exist without catch-all redirect — unmatched LAN stays direct"
  else
    # Catch-all TCP redirect
    ss_fw_ipt nat -A "$chain" -p tcp -j REDIRECT --to-ports "$port"
  fi

  ss_fw_link_chain nat PREROUTING "$chain"
  ss_fw_tcpmss_clamp
  ss_log_policy_rules 2>/dev/null || true
  ss_ok "Firewall REDIRECT configured (port $port)"
}

ss_configure_firewall_tproxy() {
  local chain="$SS_FW_CHAIN"
  local divert="${SS_FW_CHAIN}_DIVERT"
  local port="$SS_TPROXY_PORT"
  local mark="$SS_TPROXY_MARK"
  local mask="$SS_TPROXY_MASK"
  local table="$SS_TPROXY_TABLE"
  local policy_info has_rules has_catchall

  ss_activity "firewall.tproxy" "port=$port mark=$mark table=$table"
  # Policy routing
  ip rule del fwmark "$mark" lookup "$table" 2>/dev/null || true
  ip rule add fwmark "$mark" lookup "$table" 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table "$table" 2>/dev/null || true

  # DIVERT for already-transparent sockets (xrayui pattern)
  ss_fw_ensure_chain mangle "$divert"
  ss_fw_ipt mangle -A "$divert" -j MARK --set-mark "${mark}/${mask}"
  ss_fw_ipt mangle -A "$divert" -j ACCEPT
  if ! ss_fw_ipt mangle -C PREROUTING -p tcp -m socket --transparent -j "$divert" 2>/dev/null; then
    ss_fw_ipt mangle -I PREROUTING 1 -p tcp -m socket --transparent -j "$divert" || true
  fi
  if ! ss_fw_ipt mangle -C PREROUTING -p udp -m socket --transparent -j "$divert" 2>/dev/null; then
    ss_fw_ipt mangle -I PREROUTING 1 -p udp -m socket --transparent -j "$divert" || true
  fi
  # Accept marked packets in filter
  ss_iptables_init
  if ! "$SS_IPTABLES" -w -C INPUT -m mark --mark "${mark}/${mask}" -j ACCEPT 2>/dev/null; then
    "$SS_IPTABLES" -w -I INPUT 1 -m mark --mark "${mark}/${mask}" -j ACCEPT 2>/dev/null || true
  fi

  ss_fw_ensure_chain mangle "$chain"
  ss_fw_exclude_private mangle "$chain"
  ss_fw_exclude_endpoints mangle "$chain"

  case "$SS_DNS_MODE" in
  REDIRECT)
    ss_fw_ipt mangle -A "$chain" -p udp --dport 53 \
      -j TPROXY --on-port "$SS_DNS_PORT" --tproxy-mark "${mark}/${mask}"
    ;;
  BYPASS)
    ss_fw_ipt mangle -A "$chain" -p udp --dport 53 -j RETURN
    ss_fw_ipt mangle -A "$chain" -p tcp --dport 53 -j RETURN
    ;;
  esac

  policy_info=$(ss_fw_apply_client_policies mangle "$chain" tproxy)
  has_rules=${policy_info%%:*}
  has_catchall=${policy_info##*:}

  if [ "$has_rules" = "1" ] && [ "$has_catchall" != "1" ]; then
    ss_warn "Client policies exist without catch-all — unmatched LAN stays direct"
  else
    ss_fw_ipt mangle -A "$chain" -p tcp \
      -j TPROXY --on-port "$port" --tproxy-mark "${mark}/${mask}"
    ss_fw_ipt mangle -A "$chain" -p udp \
      -j TPROXY --on-port "$port" --tproxy-mark "${mark}/${mask}"
  fi

  ss_fw_link_chain mangle PREROUTING "$chain"
  ss_fw_tcpmss_clamp
  ss_log_policy_rules 2>/dev/null || true
  ss_ok "Firewall TPROXY configured (port $port, mark $mark, table $table)"
}

ss_configure_firewall() {
  local mode
  mode=$(ss_fw_detect_mode)
  case "$mode" in
  proxy)
    ss_info "Mode=proxy — skipping transparent firewall (LAN internet stays direct)"
    ss_cleanup_firewall 2>/dev/null || true
    return 0
    ;;
  tproxy | redirect)
    # Never blackhole LAN: require Xray + dokodemo port before hijacking
    if ! ss_xray_running 2>/dev/null; then
      ss_warn "Skip transparent firewall — Xray not running"
      return 1
    fi
    if ! ss_dokodemo_listening 2>/dev/null; then
      ss_warn "Skip transparent firewall — dokodemo port not listening (would kill internet)"
      return 1
    fi
    if [ "$mode" = "tproxy" ]; then
      ss_configure_firewall_tproxy
    else
      ss_configure_firewall_redirect
    fi
    ;;
  *)
    ss_configure_firewall_redirect
    ;;
  esac
}

ss_cleanup_firewall() {
  local chain="$SS_FW_CHAIN"
  local divert="${SS_FW_CHAIN}_DIVERT"
  local mark="$SS_TPROXY_MARK"
  local mask="$SS_TPROXY_MASK"
  ss_iptables_init
  ss_activity "firewall.cleanup" "chain=$chain"
  # Remove divert jumps
  while ss_fw_ipt mangle -C PREROUTING -p tcp -m socket --transparent -j "$divert" 2>/dev/null; do
    ss_fw_ipt mangle -D PREROUTING -p tcp -m socket --transparent -j "$divert"
  done
  while ss_fw_ipt mangle -C PREROUTING -p udp -m socket --transparent -j "$divert" 2>/dev/null; do
    ss_fw_ipt mangle -D PREROUTING -p udp -m socket --transparent -j "$divert"
  done
  while "$SS_IPTABLES" -w -C INPUT -m mark --mark "${mark}/${mask}" -j ACCEPT 2>/dev/null; do
    "$SS_IPTABLES" -w -D INPUT -m mark --mark "${mark}/${mask}" -j ACCEPT 2>/dev/null || break
  done

  ss_fw_unlink_chain nat PREROUTING "$chain"
  ss_fw_unlink_chain mangle PREROUTING "$chain"
  ss_fw_ipt nat -F "$chain" 2>/dev/null
  ss_fw_ipt nat -X "$chain" 2>/dev/null
  ss_fw_ipt mangle -F "$chain" 2>/dev/null
  ss_fw_ipt mangle -X "$chain" 2>/dev/null
  ss_fw_ipt mangle -F "$divert" 2>/dev/null
  ss_fw_ipt mangle -X "$divert" 2>/dev/null
  ss_fw_ip6 nat -F "$chain" 2>/dev/null
  ss_fw_ip6 nat -X "$chain" 2>/dev/null
  ss_fw_ip6 mangle -F "$chain" 2>/dev/null
  ss_fw_ip6 mangle -X "$chain" 2>/dev/null

  # Only our policy-routing table (78) — never touch xrayui table 77
  ip rule del fwmark "$SS_TPROXY_MARK" lookup "$SS_TPROXY_TABLE" 2>/dev/null || true
  ip route flush table "$SS_TPROXY_TABLE" 2>/dev/null || true
  ss_fw_tcpmss_cleanup 2>/dev/null || true

  ss_ok "Firewall cleaned up"
}

ss_restore_firewall() {
  # Called from nat-start / firewall-start / wan-start after reboot/WAN up
  if ss_xray_running 2>/dev/null; then
    if [ -f "$XRAY_CONFIG_FILE" ]; then
      if ss_firewall_is_configured; then
        # Still rebuild — WAN ifnames / NAT may have changed
        ss_info "Re-applying firewall after network event"
      fi
      ss_cleanup_firewall 2>/dev/null
      ss_configure_firewall
      ss_activity "firewall.restore" "reconfigured while running"
    fi
  elif type ss_desired_is_set >/dev/null 2>&1 && ss_desired_is_set && [ -f "$XRAY_CONFIG_FILE" ]; then
    ss_warn "Desired state set but Xray down — attempting start"
    ss_start 2>/dev/null || true
  fi
}
