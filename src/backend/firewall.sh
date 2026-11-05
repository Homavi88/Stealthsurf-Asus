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
  # ss_fw_ipt <table> <args...>
  local tbl="$1"
  shift
  iptables -w -t "$tbl" "$@" 2>/dev/null
}

ss_fw_ip6() {
  local tbl="$1"
  shift
  ip6tables -w -t "$tbl" "$@" 2>/dev/null || true
}

ss_fw_ensure_chain() {
  local tbl="$1"
  local chain="$2"
  ss_fw_ipt "$tbl" -N "$chain" 2>/dev/null || ss_fw_ipt "$tbl" -F "$chain"
  ss_fw_ip6 "$tbl" -N "$chain" 2>/dev/null || ss_fw_ip6 "$tbl" -F "$chain"
}

ss_fw_link_chain() {
  # Insert jump to STEALTHSURF at head of parent if missing
  local tbl="$1"
  local parent="$2"
  local chain="$3"
  if ! ss_fw_ipt "$tbl" -C "$parent" -j "$chain" 2>/dev/null; then
    ss_fw_ipt "$tbl" -I "$parent" 1 -j "$chain"
  fi
  if ! ss_fw_ip6 "$tbl" -C "$parent" -j "$chain" 2>/dev/null; then
    ss_fw_ip6 "$tbl" -I "$parent" 1 -j "$chain"
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

ss_fw_exclude_private() {
  local tbl="$1"
  local chain="$2"
  local cidr
  for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    ss_fw_ipt "$tbl" -A "$chain" -d "$cidr" -j RETURN
  done
  # Router itself
  local rip
  rip=$(ss_router_ip)
  [ -n "$rip" ] && ss_fw_ipt "$tbl" -A "$chain" -d "$rip" -j RETURN
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
  # Clamp MSS on SYN to avoid PMTU blackholes through tunnels
  if ! ss_fw_ipt mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    ss_fw_ipt mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  fi
}

ss_configure_firewall_redirect() {
  local chain="$SS_FW_CHAIN"
  local port="$SS_REDIRECT_PORT"
  local policy_info has_rules has_catchall

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
  ss_ok "Firewall REDIRECT configured (port $port)"
}

ss_configure_firewall_tproxy() {
  local chain="$SS_FW_CHAIN"
  local port="$SS_TPROXY_PORT"
  local mark="$SS_TPROXY_MARK"
  local mask="$SS_TPROXY_MASK"
  local table="$SS_TPROXY_TABLE"
  local policy_info has_rules has_catchall

  # Policy routing
  ip rule del fwmark "$mark" lookup "$table" 2>/dev/null || true
  ip rule add fwmark "$mark" lookup "$table" 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table "$table" 2>/dev/null || true

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
  ss_ok "Firewall TPROXY configured (port $port, mark $mark, table $table)"
}

ss_configure_firewall() {
  local mode
  mode=$(ss_fw_detect_mode)
  case "$mode" in
  proxy)
    ss_info "Mode=proxy — skipping transparent firewall"
    return 0
    ;;
  tproxy)
    ss_configure_firewall_tproxy
    ;;
  *)
    ss_configure_firewall_redirect
    ;;
  esac
}

ss_cleanup_firewall() {
  local chain="$SS_FW_CHAIN"
  ss_fw_unlink_chain nat PREROUTING "$chain"
  ss_fw_unlink_chain mangle PREROUTING "$chain"
  ss_fw_ipt nat -F "$chain" 2>/dev/null
  ss_fw_ipt nat -X "$chain" 2>/dev/null
  ss_fw_ipt mangle -F "$chain" 2>/dev/null
  ss_fw_ipt mangle -X "$chain" 2>/dev/null
  ss_fw_ip6 nat -F "$chain" 2>/dev/null
  ss_fw_ip6 nat -X "$chain" 2>/dev/null
  ss_fw_ip6 mangle -F "$chain" 2>/dev/null
  ss_fw_ip6 mangle -X "$chain" 2>/dev/null

  ip rule del fwmark "$SS_TPROXY_MARK" lookup "$SS_TPROXY_TABLE" 2>/dev/null || true
  ip route flush table "$SS_TPROXY_TABLE" 2>/dev/null || true

  # Remove our TCPMSS clamp if we added a dedicated one — leave shared clamp alone
  ss_ok "Firewall cleaned up"
}

ss_restore_firewall() {
  # Called from nat-start / firewall-start after reboot/WAN up
  if ss_xray_running 2>/dev/null || [ -f "$XRAY_PIDFILE" ]; then
    if [ -f "$XRAY_CONFIG_FILE" ]; then
      ss_cleanup_firewall 2>/dev/null
      ss_configure_firewall
    fi
  fi
}
