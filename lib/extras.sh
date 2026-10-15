# shellcheck shell=bash
# Optional features (each chosen at deploy time): unattended security upgrades,
# Proxmox firewall rules, and verification of blocklists / HTTPS web UI.

# ------------------------------------------------- unattended upgrades ------
render_auto_upgrades() {
  local on=$1
  [[ "$on" == yes ]] && on=1 || on=0
  cat <<EOF
// Managed by proxmox-dns-ha-autodeploy
APT::Periodic::Update-Package-Lists "$on";
APT::Periodic::Unattended-Upgrade "$on";
EOF
}

# Security updates only. Docker's repository is deliberately not an allowed origin, so Docker
# (and with it Technitium) is never restarted unattended - use update.sh for that.
render_unattended_policy() {
  cat <<'EOF'
// Managed by proxmox-dns-ha-autodeploy: Debian security updates only, never reboot.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
}

# Stagger the two nodes by two hours so a security update that restarts keepalived or
# docker can never hit both at once.
render_upgrade_timer() {
  local n=$1 at
  [[ "$n" == 1 ]] && at="03:30" || at="05:30"
  cat <<EOF
# Managed by proxmox-dns-ha-autodeploy: node $n upgrades at $at (other node 2h apart).
[Timer]
OnCalendar=
OnCalendar=*-*-* $at
RandomizedDelaySec=0
EOF
}

configure_unattended() {
  local n=$1 host
  host=$(node_var "$n" HOST)
  if [[ "$CFG_UNATTENDED" == yes ]]; then
    lxc_exec "$n" sh -c 'DEBIAN_FRONTEND=noninteractive apt-get -y -q install unattended-upgrades >>/var/log/proxmox-dns-ha-autodeploy-bootstrap.log 2>&1'
    push_rendered "$n" /etc/apt/apt.conf.d/20auto-upgrades 0644 render_auto_upgrades yes
    push_rendered "$n" /etc/apt/apt.conf.d/52proxmox-dns-ha-autodeploy-unattended 0644 render_unattended_policy
    lxc_exec "$n" install -d -m 755 /etc/systemd/system/apt-daily-upgrade.timer.d
    push_rendered "$n" /etc/systemd/system/apt-daily-upgrade.timer.d/proxmox-dns-ha-autodeploy.conf 0644 render_upgrade_timer "$n"
    lxc_exec "$n" systemctl daemon-reload
    lxc_exec "$n" systemctl enable -q --now apt-daily.timer apt-daily-upgrade.timer
    ok "$host: unattended security upgrades on, daily at $([[ $n == 1 ]] && echo 03:30 || echo 05:30)"
  else
    if lxc_query "$n" test -e /etc/apt/apt.conf.d/52proxmox-dns-ha-autodeploy-unattended; then
      push_rendered "$n" /etc/apt/apt.conf.d/20auto-upgrades 0644 render_auto_upgrades no
      lxc_exec "$n" rm -f /etc/apt/apt.conf.d/52proxmox-dns-ha-autodeploy-unattended \
        /etc/systemd/system/apt-daily-upgrade.timer.d/proxmox-dns-ha-autodeploy.conf
      lxc_exec "$n" systemctl daemon-reload
      ok "$host: unattended upgrades turned off"
    fi
  fi
}

verify_unattended() {
  local n=$1 out
  out=$(lxc_query "$n" sh -c 'unattended-upgrade --dry-run --debug 2>&1 | grep -m1 "Allowed origins are"')
  vcheck "$(node_var "$n" HOST): unattended-upgrades security origins only" "Debian-Security" "$out"
  [[ "$out" == *"label=Debian,"* ]] && vcheck "$(node_var "$n" HOST): no non-security Debian origin" "absent" "present"
  vcheck "$(node_var "$n" HOST): upgrade timer staggered" "$([[ $n == 1 ]] && echo 03:30 || echo 05:30)" \
    "$(lxc_query "$n" systemctl show apt-daily-upgrade.timer -p TimersCalendar --value)"
}

# ------------------------------------------------------ Proxmox firewall ----
render_firewall() {
  local n=$1 peer
  peer=$(node_ip "$(( 3 - n ))")
  cat <<EOF
# Managed by proxmox-dns-ha-autodeploy for $(node_var "$n" HOST) - rewritten on every deployment run.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p udp -dport 53 -log nolog # DNS (recursion is limited to private networks by Technitium)
IN ACCEPT -p tcp -dport 53 -log nolog # DNS over TCP, zone transfer, NOTIFY
IN ACCEPT -source $peer -p vrrp -log nolog # keepalived VRRP from the peer node
IN ACCEPT -source $CFG_ADMIN_CIDR -p tcp -dport 5380 -log nolog # Technitium web UI (HTTP)
EOF
  [[ "$CFG_WEB_HTTPS" == yes ]] && \
    echo "IN ACCEPT -source $CFG_ADMIN_CIDR -p tcp -dport 53443 -log nolog # Technitium web UI (HTTPS)"
  cat <<EOF
IN ACCEPT -source $CFG_ADMIN_CIDR -p tcp -dport 22 -log nolog # SSH
IN Ping(ACCEPT) -log nolog # ICMP echo
EOF
}

# Datacenter-level firewall must be on for guest rules to be enforced at all.
dc_firewall_enabled() { [[ "$(node_exec "$1" pvesh get /cluster/firewall/options --output-format json | jq -r '.enable // 0')" == 1 ]]; }

configure_firewall() {
  local n=$1 vmid fw tmp label
  vmid=$(node_var "$n" VMID); fw="/etc/pve/firewall/$vmid.fw"; label=$(node_label "$n")
  if [[ "$CFG_FIREWALL" != yes ]]; then
    if node_exec "$n" grep -qs 'Managed by proxmox-dns-ha-autodeploy' "$fw"; then
      node_run "$n" sed -i 's/^enable: 1$/enable: 0/' "$fw"
      ok "$(node_var "$n" HOST): firewall rules disabled"
    fi
    return 0
  fi
  if node_exec "$n" test -e "$fw" && ! node_exec "$n" grep -qs 'Managed by proxmox-dns-ha-autodeploy' "$fw"; then
    node_run "$n" cp -a "$fw" "$fw.bak-$(date +%Y%m%d%H%M%S)"
    warn "$label: existing $fw was not ours - backed up before replacing"
  fi
  tmp=$(mktemp "$STATE_DIR/fw.XXXXXX")
  render_firewall "$n" >"$tmp"
  node_run "$n" sh -c "cat > '$fw'" <"$tmp"
  rm -f "$tmp"
  # Proxmox silently drops rules it cannot parse; compare what it parsed with what we wrote.
  local want got pvenode
  want=$(render_firewall "$n" | grep -cE '^IN ')
  pvenode=$(node_exec "$n" hostname)
  got=$(node_exec "$n" pvesh get "/nodes/$pvenode/lxc/$vmid/firewall/rules" --output-format json | jq length)
  [[ "$got" == "$want" ]] || die "$label: Proxmox parsed $got of $want firewall rules in $fw"
  if dc_firewall_enabled "$n"; then
    ok "$(node_var "$n" HOST): firewall rules active (DNS open; UI/SSH from $CFG_ADMIN_CIDR; VRRP from peer)"
  else
    FW_INACTIVE+=("$n")
    warn "$(node_var "$n" HOST): rules written to $fw on $label, but NOT enforced:"
    warn "  the datacenter firewall is disabled on $label. Enabling it also filters the host itself"
    warn "  (default host policy DROP; SSH/8006 only from the local network), so this script never"
    warn "  turns it on. To enforce: Datacenter -> Firewall -> Options -> Firewall: Yes on $label,"
    warn "  after checking the host rules allow your management access."
  fi
}
declare -a FW_INACTIVE=()

# ---------------------------------------------------- blocklists / HTTPS ----
# First real domain listed in a blocklist (hosts or Adblock-Plus format), to test blocking.
sample_blocked_domain() {
  curl -fsS -m 30 "$1" 2>/dev/null | head -c 2000000 \
    | sed -nE 's/^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+([a-z0-9.-]+\.[a-z]{2,})$/\2/p; s/^\|\|([a-z0-9.-]+\.[a-z]{2,})\^$/\1/p' \
    | grep -vE '^(localhost|local|0\.0\.0\.0)' | sed -n '20p' || true
}

verify_blocklists() {
  [[ "$CFG_BLOCKLISTS" == yes ]] || return 0
  local url d n i ans
  url=${CFG_BLOCKLIST_URLS%% *}
  d=$(sample_blocked_domain "$url")
  [[ -n "$d" ]] || { warn "Could not read a sample domain from $url - skipping blocklist check"; return 0; }
  for n in 1 2; do
    # Lists download in the background after settings are applied; give them time.
    # Technitium answers blocked names with NXDOMAIN + Extended DNS Error 15 (Blocked), or with
    # 0.0.0.0 when its blocking type is set to "Any Address".
    for (( i = 0; i < 40; i++ )); do
      ans=$(dq @"$(node_ip "$n")" "$d" A)
      if grep -q 'EDE: 15 (Blocked)' <<<"$ans" || grep -qE "^$d\.\s.*\s0\.0\.0\.0$" <<<"$ans"; then ans=blocked; break; fi
      ans=$(grep -o 'status: [A-Z]*' <<<"$ans" | head -1)
      sleep 3
    done
    vcheck "$(node_var "$n" NS): blocklist blocks $d" "blocked" "$ans"
  done
}

verify_https() {
  [[ "$CFG_WEB_HTTPS" == yes ]] || return 0
  local n ip
  for n in 1 2; do
    ip=$(node_ip "$n")
    vcheck "$(node_var "$n" HOST): HTTPS web UI https://$ip:53443" "200" \
      "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$ip:53443/" || true)"
    vcheck "$(node_var "$n" HOST): HTTP :5380 redirects to HTTPS" "30" \
      "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$ip:5380/" || true)"
  done
}

verify_firewall() {
  [[ "$CFG_FIREWALL" == yes ]] || return 0
  local n
  for n in 1 2; do
    vcheck "$(node_var "$n" HOST): firewall rule file present" "Managed by proxmox-dns-ha-autodeploy" \
      "$(node_exec "$n" head -1 "/etc/pve/firewall/$(node_var "$n" VMID).fw" 2>/dev/null)"
    if dc_firewall_enabled "$n"; then
      vcheck "$(node_var "$n" HOST): firewall enforced on $(node_label "$n")" "running" "$(node_exec "$n" pve-firewall status 2>&1)"
    else
      printf '  %sINFO%s  %-52s %s\n' "$C_YELLOW" "$C_RESET" "$(node_var "$n" HOST): firewall enforced" "no - datacenter firewall off on $(node_label "$n")"
    fi
  done
}

verify_extras() {
  section "Optional feature verification"
  VERIFY_FAIL=0
  local n
  if [[ "$CFG_UNATTENDED" == yes ]]; then for n in 1 2; do verify_unattended "$n"; done; fi
  verify_firewall
  verify_https
  verify_blocklists
  (( VERIFY_FAIL == 0 )) || die "$VERIFY_FAIL optional-feature check(s) failed"
  ok "Optional feature checks passed"
}
