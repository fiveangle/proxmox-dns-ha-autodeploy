# shellcheck shell=bash
# LXC creation and start-up (pct / pveam), on whichever host each node lives.

DEPLOY_TAG="proxmox-dns-ha-autodeploy"

ensure_template() {
  local n=$1 tstore
  tstore=$(node_var "$n" TEMPLATE_STORAGE)
  if node_exec "$n" pveam list "$tstore" 2>/dev/null | grep -q "vztmpl/$CFG_TEMPLATE"; then
    ok "Template $CFG_TEMPLATE cached on $(node_label "$n")"
    return
  fi
  info "Downloading template $CFG_TEMPLATE to $tstore on $(node_label "$n")"
  node_run "$n" pveam update
  node_run "$n" pveam download "$tstore" "$CFG_TEMPLATE"
}

# pct_create_args N KEYFILE -> fills global array PCT_ARGS for node N
pct_create_args() {
  local n=$1 keyfile=$2 net vlan
  vlan=$(node_var "$n" VLAN)
  net="name=eth0,bridge=$(node_var "$n" BRIDGE),ip=$(node_var "$n" IP),gw=$CFG_GW,firewall=1"
  [[ -n "$vlan" ]] && net+=",tag=$vlan"
  PCT_ARGS=(
    pct create "$(node_var "$n" VMID)" "$(node_var "$n" TEMPLATE_STORAGE):vztmpl/$CFG_TEMPLATE"
    --hostname "$(node_var "$n" HOST)"
    --ostype debian
    --unprivileged 1
    --features nesting=1,keyctl=1
    --cores "$CFG_CORES" --memory "$CFG_MEMORY" --swap "$CFG_SWAP"
    --rootfs "$(node_var "$n" STORAGE):$CFG_DISK"
    --net0 "$net"
    --nameserver "$CFG_UPSTREAM_IPS"
    --searchdomain "$CFG_SEARCHDOMAIN"
    --ssh-public-keys "$keyfile"
    --timezone "$CFG_TZ"
    --onboot "$([[ $CFG_ONBOOT == yes ]] && echo 1 || echo 0)"
    --startup "order=$n"
    --tags "dns;technitium;keepalived;$DEPLOY_TAG"
    --description "Technitium DNS ($(node_var "$n" NS)) + keepalived, VIP $CFG_VIP - being deployed by proxmox-dns-ha-autodeploy."
  )
}

create_lxc() {
  local n=$1 keyfile=$CFG_SSH_KEY_FILE
  ensure_template "$n"
  if node_is_remote "$n"; then
    keyfile="/tmp/proxmox-dns-ha-autodeploy-key.$$.pub"
    node_copy "$n" "$CFG_SSH_KEY_FILE" "$keyfile"
  fi
  pct_create_args "$n" "$keyfile"
  info "Creating LXC $(node_var "$n" VMID) ($(node_var "$n" HOST)) on $(node_label "$n")"
  node_run "$n" "${PCT_ARGS[@]}"
  node_is_remote "$n" && node_run "$n" rm -f "$keyfile"
  ok "Created $(node_var "$n" HOST)"
}

start_lxc() {
  local n=$1 vmid
  vmid=$(node_var "$n" VMID)
  if [[ "$DRY_RUN" != 1 ]] && node_exec "$n" pct status "$vmid" | grep -q running; then
    ok "$(node_var "$n" HOST) already running"
  else
    node_run "$n" pct start "$vmid"
  fi
}

# Wait until the container has its IP, a default route and working DNS.
wait_for_lxc_network() {
  local n=$1 ip i
  [[ "$DRY_RUN" == 1 ]] && return 0
  ip=$(node_ip "$n")
  for (( i = 0; i < 60; i++ )); do
    if lxc_query "$n" sh -c "ip -4 -o addr show dev eth0 | grep -q ' $ip/' && getent hosts deb.debian.org >/dev/null" 2>/dev/null; then
      ok "$(node_var "$n" HOST) is online ($ip, DNS works)"
      return 0
    fi
    sleep 2
  done
  die "$(node_var "$n" HOST) did not get network/DNS within 120s"
}

provision_lxc() {
  local n=$1
  if [[ "${RESUME[$n]:-0}" == 1 ]]; then
    ok "Reusing existing $(node_var "$n" HOST) (VMID $(node_var "$n" VMID))"
  else
    create_lxc "$n"
  fi
  start_lxc "$n"
  wait_for_lxc_network "$n"
}

# retire_nodes — stop the LXCs of nodes no longer part of the deployment (RETIRED, found by
# preflight) once the others have dropped them from VRRP and zone transfers, and remove their
# records from the main zone. Never destroyed: that is left to the admin.
retire_nodes() {
  local n vmid host
  for n in "${RETIRED[@]}"; do
    vmid=$(node_var "$n" VMID); host=$(node_var "$n" HOST)
    forget_node_records "$n"
    node_run "$n" pct set "$vmid" --onboot 0
    node_run "$n" pct shutdown "$vmid" --timeout 60 || node_run "$n" pct stop "$vmid"
    ok "$host (VMID $vmid on $(node_label "$n")) stopped and no longer starts on boot"
    info "Remove it when you no longer need it: pct destroy $vmid$(node_is_remote "$n" && echo " (on $(node_host "$n"))")"
  done
  return 0
}

# Prove all LXCs share one L2 segment: node 1 must learn each secondary's real MAC via ARP.
# (Across a router it would see the gateway's MAC instead, and a VIP could never float.)
verify_same_l2() {
  local n mac seen ip host
  [[ "$DRY_RUN" == 1 ]] && { info "[dry-run] would verify $(all_word) LXCs share one L2 segment"; return 0; }
  for n in $(secondary_nodes); do
    ip=$(node_ip "$n"); host=$(node_var "$n" HOST)
    mac=$(node_exec "$n" pct config "$(node_var "$n" VMID)" | sed -nE 's/^net0:.*hwaddr=([0-9A-Fa-f:]+).*/\1/p')
    lxc_query 1 ping -c 2 -W 1 "$ip" >/dev/null 2>&1 || die "$CFG_HOST1 cannot reach $host ($ip)"
    seen=$(lxc_query 1 ip neigh show "$ip" | sed -nE 's/.*lladdr ([0-9a-f:]+).*/\1/p')
    if [[ "${seen,,}" == "${mac,,}" ]]; then
      ok "$CFG_HOST1 and $host share one L2 segment (ARP $ip -> $seen)"
    else
      die "$CFG_HOST1 reaches $host through a router (ARP gave ${seen:-nothing}, expected $mac) - a VIP cannot float between them"
    fi
  done
}
