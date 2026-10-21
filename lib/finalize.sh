# shellcheck shell=bash
# Phase 6: LXC resolver, SSH host-key pinning for the helpers, live failover test, report.

# Each LXC resolves through its own Technitium first (so it sees the local zone), with the
# upstream as fallback: if Technitium is down, port 53 is closed and glibc moves on at once.
configure_resolver() {
  local n=$1 host conf
  host=$(node_var "$n" HOST)
  node_run "$n" pct set "$(node_var "$n" VMID)" --nameserver "127.0.0.1 $CFG_UPSTREAM_IPS"
  conf="search $CFG_SEARCHDOMAIN"$'\n'"nameserver 127.0.0.1"
  local ip; for ip in $CFG_UPSTREAM_IPS; do conf+=$'\n'"nameserver $ip"; done
  # pct set applies at the next container start; write the live file now as well.
  lxc_exec "$n" sh -c "printf '%s\n' \"\$1\" > /etc/resolv.conf" _ "$conf"
  if [[ -n "$CFG_ZONE" ]]; then
    lxc_query "$n" getent hosts "$CFG_NS2.$CFG_ZONE" >/dev/null \
      || die "$host: cannot resolve $CFG_NS2.$CFG_ZONE through its own resolver"
  fi
  lxc_query "$n" getent hosts deb.debian.org >/dev/null || die "$host: cannot resolve deb.debian.org"
  ok "$host: resolver is 127.0.0.1 (fallback ${CFG_UPSTREAM_IPS// /, })"
}

# Pin each LXC's SSH host keys, read through pct exec (a trusted channel), so the helpers'
# first SSH connection never has to trust an unknown key.
pin_lxc_hostkeys() {
  local n ip keys
  for n in $(all_nodes); do
    ip=$(node_ip "$n")
    keys=$(lxc_query "$n" sh -c 'cat /etc/ssh/ssh_host_*_key.pub')
    [[ -n "$keys" ]] || die "$(node_var "$n" HOST): no SSH host keys found"
    ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true   # a rebuilt LXC has new keys
    awk -v ip="$ip" '{print ip, $1, $2}' <<<"$keys" >>"$KNOWN_HOSTS"
  done
  rm -f "$KNOWN_HOSTS.old"
  # shellcheck source=lib/remote.sh
  ( source "$SCRIPT_DIR/lib/remote.sh"
    for n in $(all_nodes); do
      lxc_ssh "$n" true || die "Direct SSH to $(node_var "$n" HOST) ($(node_ip "$n")) failed - helpers need it"
    done )
  ok "SSH host keys of $(all_word) LXCs pinned; direct SSH for the helper scripts works"
}

# ----------------------------------------------------- live failover test ---
PROBE_FILE="$STATE_DIR/probe.log"

probe_start() {
  : >"$PROBE_FILE"
  local want=""
  [[ -n "$CFG_ZONE" ]] && want=$(node_ip 2)
  ( while :; do
      t=$(date +%s.%N)
      if [[ -n "$want" ]]; then
        dig +time=1 +tries=1 +short @"$CFG_VIP" "$CFG_NS2.$CFG_ZONE" A 2>/dev/null | grep -qx "$want" && r=ok || r=FAIL
      else
        dig +time=1 +tries=1 @"$CFG_VIP" localhost A 2>/dev/null | grep -q 'status: NOERROR' && r=ok || r=FAIL
      fi
      echo "$t $r" >>"$PROBE_FILE"; sleep 0.2
    done ) &
  PROBE_PID=$!
}

# probe_stop -> prints "probes failed longest_outage_seconds"
probe_stop() {
  kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null || true
  awk '{ if ($2=="FAIL") { if (!s) s=$1; f++ } else if (s) { g=$1-s; if (g>m) m=g; s=0 } n++ }
       END { if (s) { g=$1-s; if (g>m) m=g }; printf "%d %d %.1f\n", n, f, m }' "$PROBE_FILE"
}

# wait_for_new_holder OLD MAX_SECONDS — 0 once a single node other than OLD holds the VIP; sets
# NEW_HOLDER (with more than one secondary: the healthy one with the highest priority).
wait_for_new_holder() {
  local s=$SECONDS h
  while (( SECONDS - s < $2 )); do
    h=$(vip_holders)
    [[ "$h" =~ ^[0-9]$ && "$h" != "$1" ]] && { NEW_HOLDER=$h; return 0; }
    sleep 0.5
  done
  return 1
}

run_failover_test() {
  local master backup d=$CFG_SERVICE_DIR r1 r2 split=0 h
  section "Live failover test"
  master=$(vip_holders)
  [[ "$master" =~ ^[0-9]$ ]] || die "VIP must be on exactly one node before the test (holders: ${master:-none})"
  info "Stopping Technitium on $(node_var "$master" HOST) (current MASTER); probing $CFG_VIP every 0.2s"
  probe_start; sleep 2
  lxc_exec "$master" docker compose --project-directory "$d" stop >/dev/null 2>&1
  wait_for_new_holder "$master" 20 || { lxc_exec "$master" docker compose --project-directory "$d" start >/dev/null 2>&1; probe_stop >/dev/null; die "VIP did not move to another node"; }
  backup=$NEW_HOLDER
  sleep 3; read -r _ _ r1 < <(probe_stop)
  ok "Failover to $(node_var "$backup" HOST): longest DNS outage ${r1}s"

  info "Starting Technitium again; VIP returns to $CFG_HOST1 after preempt_delay (60s)"
  probe_start
  lxc_exec "$master" docker compose --project-directory "$d" start >/dev/null 2>&1
  local s=$SECONDS want=1
  while (( SECONDS - s < 150 )); do
    h=$(vip_holders); [[ "$h" == *" "* ]] && split=$((split+1)); [[ "$h" == "$want" ]] && break; sleep 1
  done
  sleep 3; read -r _ _ r2 < <(probe_stop)
  [[ "$(vip_holders)" == 1 ]] || die "VIP did not return to $CFG_HOST1 within 150s (holders: $(vip_holders))"
  (( split == 0 )) || die "Two nodes held the VIP at the same time ($split samples) - check VRRP between the nodes"
  ok "Failback to $CFG_HOST1 after $((SECONDS - s))s: longest DNS outage ${r2}s, never held by two nodes"
  awk -v a="$r1" -v b="$r2" 'BEGIN { exit !(a <= 5 && b <= 5) }' || warn "An outage exceeded 5s - investigate before production use"
}

# ------------------------------------------------------------ LXC notes ----
# Markdown shown in the container's Notes panel in the Proxmox UI: what this LXC is, how to
# reach it and how to operate the pair. Rewritten on every run, so it always matches reality.
render_notes() {
  local n=$1 m ui role h1 peers="" group="pair"
  (( $(node_count) > 2 )) && group="group"
  h1=$(node_exec 1 hostname -s 2>/dev/null || node_label 1)
  for m in $(all_nodes); do
    (( m == n )) && continue
    peers+="${peers:+, }$(node_var "$m" HOST) ($(node_ip "$m")) on $(node_exec "$m" hostname -s 2>/dev/null || node_label "$m")"
  done
  [[ "$CFG_WEB_HTTPS" == yes ]] && ui="https://$(node_ip "$n"):53443" || ui="http://$(node_ip "$n"):5380"
  [[ "$n" == 1 ]] && role="VRRP MASTER (priority 150), zone primary - edit records here" \
                  || role="VRRP BACKUP (priority $(node_priority "$n")), zone secondary - follows $CFG_NS1"
  cat <<EOF
### $(node_var "$n" HOST) - Technitium DNS ($(node_var "$n" NS))

$([[ $group == pair ]] && echo "One half of a highly available DNS pair" || echo "One of $(node_count) servers in a highly available DNS group"). Clients use the virtual IP **$CFG_VIP**.

- **This node:** $(node_ip "$n") - $role
- **Peer$( (( $(node_count) > 2 )) && echo s):** $peers
- **Web UI:** [$ui]($ui) - login \`admin\`
- **Zones:** ${CFG_ZONE:-none}$(for z in ${CFG_EXTRA_ZONES:-}; do printf ', %s' "$z"; done)${CFG_LAN_DNS:+
- **LAN hostnames:** \`*.$CFG_LAN_DOMAIN\`$([[ $CFG_LAN_PTR == yes ]] && echo ' and reverse lookups') from the DHCP server $CFG_LAN_DNS}
- **Service:** \`$CFG_SERVICE_DIR\` (docker compose)

Manage the $([[ $group == pair ]] && echo pair || echo servers) from $h1: \`$SCRIPT_DIR/helpers/status.sh\`, \`update.sh\`, \`zones.sh\`, \`lan.sh\`, \`backup.sh\`, \`failover-test.sh\`, \`reset-admin.sh\`

---
Deployed with [proxmox-dns-ha-autodeploy]($PROJECT_URL) - by David Johnson ([@fiveangle](https://github.com/fiveangle))
EOF
}

set_lxc_notes() {
  local n
  for n in $(all_nodes); do
    node_run "$n" pct set "$(node_var "$n" VMID)" --description "$(render_notes "$n")"
  done
  ok "Proxmox Notes written for $(all_word) LXCs"
}

# ---------------------------------------------------------- final report ----
final_report() {
  local proto=http port=5380 n
  [[ "$CFG_WEB_HTTPS" == yes ]] && { proto=https; port=53443; }
  section "Deployment complete"
  cat <<EOF
  ${C_BOLD}Virtual IP (give this to clients):  $CFG_VIP${C_RESET}   (currently on $(node_var "$(vip_holders)" HOST 2>/dev/null || echo '?'))

  Node   LXC            Host                    IP               Technitium        Web UI
EOF
  for n in $(all_nodes); do
    printf '  %-6s %-14s %-23s %-16s %-17s %s\n' "$n" "$(node_var "$n" HOST) ($(node_var "$n" VMID))" \
      "$(node_label "$n")" "$(node_ip "$n")" "$(tech_fqdn "$n")" "$proto://$(node_ip "$n"):$port"
  done
  cat <<EOF

  Admin login        admin / password in $CREDENTIALS_FILE
  Answers file       $CONFIG_FILE_DEFAULT  (re-run: $SCRIPT_DIR/deploy.sh --config <file>)
  Edit DNS records   on $CFG_NS1 ($(node_ip 1)) only - $(and_list $(for n in $(secondary_nodes); do node_var "$n" NS; done)) $( (( $(node_count) == 2 )) && echo receives || echo receive) changes within ~10s
  Helpers            $SCRIPT_DIR/helpers/status.sh
                     $SCRIPT_DIR/helpers/update.sh [tag]      rolling Technitium upgrade
                     $SCRIPT_DIR/helpers/reset-admin.sh       admin password recovery
                     $SCRIPT_DIR/helpers/failover-test.sh     repeat the live failover test
                     $SCRIPT_DIR/helpers/zones.sh add <zone>  another local zone (+ copies on the secondaries)
                     $SCRIPT_DIR/helpers/lan.sh               LAN hostnames from your DHCP server
                     $SCRIPT_DIR/helpers/backup.sh            back up $(all_word) servers; check drift
  Quick reference    each LXC's Notes panel in the Proxmox UI (role, peer, VIP, web UI link, zones)

  Next steps
    1. Point your DHCP server's DNS option at $CFG_VIP (optionally list $(and_list $(for n in $(all_nodes); do node_ip "$n"; done)) after it).
    2. Recreate any records from your current DNS server on $CFG_NS1 (web UI, zone $CFG_ZONE).
    3. Test from a client, then retire the old DNS server.
EOF
  if (( ${#FW_INACTIVE[@]} )); then
    echo "    4. Firewall rules are NOT enforced for: $(for n in "${FW_INACTIVE[@]}"; do printf '%s ' "$(node_var "$n" HOST)"; done)(datacenter firewall off on that host)."
  fi
  [[ -n "${CFG_LAN_DNS:-}" ]] && lan_dhcp_instructions
  if nodes_share_host; then
    echo; warn "$( (( $(node_count) == 2 )) && echo 'Both nodes run' || echo 'All nodes run') on one Proxmox host: a host reboot stops DNS. Consider moving a secondary."
  fi
}
