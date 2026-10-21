# shellcheck shell=bash
# keepalived (native apt package) in each LXC: one VRRP instance holding the VIP,
# unicast between all nodes, health-checked against the local Technitium.

KA_DIR=/usr/local/libexec/proxmox-dns-ha-autodeploy

# Health check: Technitium answers "localhost" authoritatively from its built-in zone, so
# this tests the local DNS service only. An upstream/internet outage can never fail it
# (which would otherwise put EVERY node in FAULT and drop the VIP entirely).
render_check_script() {
  cat <<'EOF'
#!/bin/sh
# keepalived health check (managed by proxmox-dns-ha-autodeploy): local Technitium must answer.
out=$(dig +time=1 +tries=1 @127.0.0.1 localhost A 2>/dev/null) || exit 1
echo "$out" | grep -q 'status: NOERROR' || exit 1
echo "$out" | grep -qE 'flags:[a-z ]* aa' || exit 1
exit 0
EOF
}

render_notify_script() {
  cat <<'EOF'
#!/bin/sh
# keepalived notify hook (managed by proxmox-dns-ha-autodeploy): $1=GROUP|INSTANCE $2=name $3=state $4=priority
logger -t keepalived-notify "VRRP $2 -> $3 (priority ${4:-?}) on $(hostname)"
EOF
}

render_keepalived_conf() {
  local n=$1 m peers="" prio prefix
  for m in $(all_nodes); do (( m == n )) || peers+="    $(node_ip "$m")"$'\n'; done
  prio=$(node_priority "$n"); prefix=${CFG_IP1#*/}
  cat <<EOF
# Managed by proxmox-dns-ha-autodeploy - changes are overwritten on the next deployment run.
global_defs {
  router_id $(node_var "$n" HOST)
  enable_script_security
  script_user keepalived_script
  vrrp_garp_master_delay 1
  vrrp_garp_master_repeat 3
  vrrp_garp_master_refresh 30
}

vrrp_script chk_technitium {
  script "$KA_DIR/check_technitium.sh"
  interval 1
  timeout 2
  fall 2        # 2 failed checks (~2s) -> FAULT, VIP released
  rise 3        # 3 good checks before it may hold the VIP again
}

vrrp_instance VI_DNS {
  state BACKUP              # $(all_word) start as BACKUP so preempt_delay applies
  interface eth0
  virtual_router_id $CFG_VRID
  priority $(printf '%-3s' "$prio")            # $CFG_HOST1=150 (preferred)$(for m in $(secondary_nodes); do printf ', %s=%s' "$(node_var "$m" HOST)" "$(node_priority "$m")"; done)
  advert_int 1
  preempt_delay 60          # failback to $CFG_HOST1 only after 60s of health
  unicast_src_ip $(node_ip "$n")
  unicast_peer {
${peers%$'\n'}
  }
  authentication {
    auth_type PASS
    auth_pass $VRRP_AUTH_PASS
  }
  virtual_ipaddress {
    $CFG_VIP/$prefix dev eth0 label eth0:vip
  }
  track_script {
    chk_technitium
  }
  notify "$KA_DIR/notify.sh"
}
EOF
}

deploy_keepalived() {
  local n=$1 host changed
  host=$(node_var "$n" HOST)
  lxc_exec "$n" sh -c "id keepalived_script >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin keepalived_script"
  lxc_exec "$n" install -d -m 755 "$KA_DIR"
  push_rendered "$n" "$KA_DIR/check_technitium.sh" 0755 render_check_script
  push_rendered "$n" "$KA_DIR/notify.sh" 0755 render_notify_script
  push_rendered "$n" /etc/keepalived/keepalived.conf.new 0600 render_keepalived_conf "$n"
  # Note: in "--config-test=X", X is a LOG file. -t -l -f tests the given config and prints
  # any problem to stdout; a valid config prints nothing. Unknown keywords are only warnings
  # for keepalived, so any output at all counts as a failure here.
  local test_out
  test_out=$(lxc_query "$n" sh -c 'timeout 15 keepalived -t -l -f /etc/keepalived/keepalived.conf.new 2>&1; echo "rc=$?"')
  if [[ "$(tail -1 <<<"$test_out")" != "rc=0" || $(wc -l <<<"$test_out") -gt 1 ]]; then
    err "$host: generated keepalived.conf failed the config test:"
    sed '$d; s/^/    /' <<<"$test_out" >&2
    die "keepalived configuration rejected - the running configuration was left untouched"
  fi

  # Only swap the config in (and reload) when it actually changed.
  if lxc_query "$n" cmp -s /etc/keepalived/keepalived.conf.new /etc/keepalived/keepalived.conf; then
    lxc_exec "$n" rm -f /etc/keepalived/keepalived.conf.new
    changed=no
  else
    lxc_exec "$n" mv /etc/keepalived/keepalived.conf.new /etc/keepalived/keepalived.conf
    changed=yes
  fi
  lxc_exec "$n" systemctl enable -q keepalived
  if ! lxc_query "$n" systemctl -q is-active keepalived; then
    lxc_exec "$n" systemctl start keepalived
    ok "$host: keepalived started (priority $(node_priority "$n"))"
  elif [[ "$changed" == yes ]]; then
    lxc_exec "$n" systemctl reload keepalived
    ok "$host: keepalived configuration updated and reloaded"
  else
    ok "$host: keepalived running, configuration unchanged"
  fi
}

# vip_holders -> space-separated list of node numbers whose eth0 currently carries the VIP
vip_holders() {
  local n out=""
  for n in $(all_nodes); do
    if lxc_query "$n" ip -4 -o addr show dev eth0 2>/dev/null | grep -q " $CFG_VIP/"; then out+="$n "; fi
  done
  echo "${out% }"
}

# Wait until exactly one node holds the VIP (node 1 expected on a healthy start).
wait_for_vip() {
  local i holders
  for (( i = 0; i < 45; i++ )); do
    holders=$(vip_holders)
    if [[ "$holders" =~ ^[0-9]$ ]]; then
      ok "VIP $CFG_VIP is held by $(node_var "$holders" HOST) only"
      [[ "$holders" == 1 ]] || warn "VIP is on $(node_var "$holders" HOST); it moves to $CFG_HOST1 after 60s of health (preempt_delay)"
      return 0
    fi
    sleep 2
  done
  die "VIP $CFG_VIP not settled on exactly one node after 90s (holders: ${holders:-none})"
}

verify_vip() {
  section "VIP verification"
  VERIFY_FAIL=0
  local z=$CFG_ZONE
  vcheck "VIP answers: debian.org A" "NOERROR" "$(dq @"$CFG_VIP" debian.org A | grep -o 'status: [A-Z]*' | cut -d' ' -f2)"
  vcheck "VIP answers over TCP" "NOERROR" "$(dq +tcp @"$CFG_VIP" debian.org A | grep -o 'status: [A-Z]*' | cut -d' ' -f2)"
  [[ -n "$z" ]] && vcheck "VIP answers local zone: $CFG_NS2.$z" "$(node_ip 2)" "$(dq +short @"$CFG_VIP" "$CFG_NS2.$z" A)"
  local n
  for n in $(all_nodes); do
    vcheck "keepalived state $(node_var "$n" HOST)" "$( (( n == 1 )) && echo MASTER || echo BACKUP)" "$(ka_state "$n")"
  done
  (( VERIFY_FAIL == 0 )) || die "$VERIFY_FAIL VIP check(s) failed"
  ok "VIP checks passed"
}

# ka_state N -> last VRRP state keepalived logged on node N
ka_state() {
  lxc_query "$1" sh -c "journalctl -t keepalived-notify -n 20 --no-pager -o cat 2>/dev/null | sed -n 's/.* -> \([A-Z]*\) .*/\1/p' | tail -1"
}
