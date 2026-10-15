# shellcheck shell=bash
# Pre-flight checks: run before anything on any host is changed.

PF_FAIL=0
pf_ok()   { ok "$*"; }
pf_warn() { warn "$*"; }
pf_fail() { err "$*"; PF_FAIL=$((PF_FAIL+1)); }

preflight_host() {
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox VE host"
  [[ -d /etc/pve ]] && command -v pveversion >/dev/null || die "This does not look like a Proxmox VE host"
  require_cmd pct pveam pvesh pvesm jq curl ip ssh ssh-keygen ssh-keyscan ping
  install -d -m 700 "$STATE_DIR"
}

# All IPv4 addresses statically assigned to any guest known to node N's host.
guest_config_ips() {
  node_exec "$1" bash -c 'cat /etc/pve/nodes/*/lxc/*.conf /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null' \
    | grep -oE '(ip=|ipconfig[0-9]+: ip=)([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || true
}

# ip_responds IP — true if anything answers ping or is in the ARP cache as reachable.
ip_responds() {
  ping -c 2 -W 1 "$1" >/dev/null 2>&1 && return 0
  ip neigh show "$1" 2>/dev/null | grep -qE 'REACHABLE|STALE|DELAY|PERMANENT' && return 0
  return 1
}

# doh_probe URL IP — send a real RFC 8484 query (www.example.com A) to URL, pinned to IP.
doh_probe() {
  local url=$1 ip=$2 host
  host=${url#https://}; host=${host%%/*}; host=${host%%:*}
  curl -fsS -m 10 -o /dev/null --resolve "$host:443:$ip" \
    -H 'accept: application/dns-message' \
    "$url?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB"
}

# ct_is_ours N — node N's VMID exists and was created by this script for this node.
ct_is_ours() {
  local cfg
  cfg=$(node_exec "$1" pct config "$(node_var "$1" VMID)" 2>/dev/null) || return 1
  grep -qE "^tags:.*$DEPLOY_TAG" <<<"$cfg" && grep -qx "hostname: $(node_var "$1" HOST)" <<<"$cfg"
}

ct_exists() { node_exec "$1" pct status "$(node_var "$1" VMID)" >/dev/null 2>&1; }

preflight_node() {
  local n=$1 vmid host label ver used names avail_kib need_kib tstore
  vmid=$(node_var "$n" VMID); host=$(node_var "$n" HOST); label=$(node_label "$n")
  printf '  %sNode %s: %s (VMID %s) on %s%s\n' "$C_BOLD" "$n" "$host" "$vmid" "$label" "$C_RESET"

  ver=$(node_exec "$n" pveversion 2>/dev/null | grep -oE 'pve-manager/[0-9]+' | cut -d/ -f2 || true)
  if [[ -z "$ver" ]]; then pf_fail "Cannot run pveversion on $label"
  elif (( ver < 8 )); then pf_fail "$label runs Proxmox VE $ver; 8 or newer is required"
  else pf_ok "$label runs Proxmox VE $ver"; fi

  if ct_is_ours "$n"; then
    pf_ok "VMID $vmid already holds $host from a previous run - it will be reused"
    RESUME[$n]=1
  else
    RESUME[$n]=0
    used=" $(used_vmids "$n" | tr '\n' ' ') "
    [[ "$used" == *" $vmid "* ]] && pf_fail "VMID $vmid is already in use on $label" || pf_ok "VMID $vmid is free"
    names=$(node_exec "$n" pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].name')
    grep -qx "$host" <<<"$names" && pf_warn "A guest named '$host' already exists on $label (allowed, but confusing)" \
      || pf_ok "Hostname '$host' not used on $label"
  fi

  PROMPT_NODE=$n
  v_bridge "$(node_var "$n" BRIDGE)" && pf_ok "Bridge $(node_var "$n" BRIDGE) exists" || pf_fail "Bridge $(node_var "$n" BRIDGE) not found on $label"
  PROMPT_NODE=1

  if [[ "${RESUME[$n]}" == 0 ]]; then
    avail_kib=$(node_exec "$n" pvesm status --storage "$(node_var "$n" STORAGE)" 2>/dev/null | awk 'NR==2 {print $6}')
    need_kib=$(( CFG_DISK * 2 * 1024 * 1024 ))
    if ! is_int "${avail_kib:-}"; then
      pf_fail "Cannot read free space of storage $(node_var "$n" STORAGE) on $label"
    elif (( avail_kib < need_kib )); then
      pf_fail "Storage $(node_var "$n" STORAGE) has $((avail_kib/1024/1024)) GiB free, need $((need_kib/1024/1024)) GiB"
    else
      pf_ok "Storage $(node_var "$n" STORAGE) has $((avail_kib/1024/1024)) GiB free"
    fi

    tstore=$(node_var "$n" TEMPLATE_STORAGE)
    if node_exec "$n" pveam list "$tstore" 2>/dev/null | grep -q "vztmpl/$CFG_TEMPLATE"; then
      pf_ok "Template is cached on $tstore"
    elif node_exec "$n" pveam available --section system 2>/dev/null | awk '{print $2}' | grep -qx "$CFG_TEMPLATE"; then
      pf_ok "Template will be downloaded to $tstore"
    else
      pf_fail "Template $CFG_TEMPLATE not available on $label (run: pveam update)"
    fi
  fi
}

declare -a RESUME=()

preflight_all() {
  section "Pre-flight checks"
  PF_FAIL=0
  local ip n used_ips owner

  preflight_node 1
  preflight_node 2
  if nodes_share_host && [[ "$CFG_VMID1" == "$CFG_VMID2" ]]; then pf_fail "VMIDs must differ on one host"; fi

  printf '  %sNetwork%s\n' "$C_BOLD" "$C_RESET"
  used_ips=$(guest_config_ips 1)
  node_is_remote 2 && used_ips+=$'\n'$(guest_config_ips 2)
  for ip in "${CFG_IP1%/*}" "${CFG_IP2%/*}" "$CFG_VIP"; do
    owner=""
    [[ "$ip" == "${CFG_IP1%/*}" && "${RESUME[1]}" == 1 ]] && owner=1
    [[ "$ip" == "${CFG_IP2%/*}" && "${RESUME[2]}" == 1 ]] && owner=2
    if [[ -n "$owner" ]]; then
      pf_ok "$ip belongs to $(node_var "$owner" HOST) from a previous run"
    elif grep -qx "$ip" <<<"$used_ips"; then
      pf_fail "$ip is assigned in another guest's Proxmox config"
    elif [[ "$ip" == "$CFG_VIP" && ( "${RESUME[1]}" == 1 || "${RESUME[2]}" == 1 ) ]]; then
      pf_ok "$ip (VIP) - skipping liveness test, nodes from a previous run may hold it"
    elif ip_responds "$ip"; then
      pf_fail "$ip answers on the network - already in use"
    else
      pf_ok "$ip is free"
    fi
  done
  if [[ -z "$CFG_VLAN1" ]]; then
    ping -c 1 -W 1 "$CFG_GW" >/dev/null 2>&1 && pf_ok "Gateway $CFG_GW reachable" || pf_warn "Gateway $CFG_GW did not answer ping"
  else
    pf_warn "VLAN $CFG_VLAN1 in use: IP/gateway checks from this host may be inaccurate"
  fi
  if node_is_remote 2; then
    node_exec 2 ping -c 1 -W 1 "$CFG_GW" >/dev/null 2>&1 \
      && pf_ok "Gateway $CFG_GW reachable from $CFG_NODE2_HOST" \
      || pf_warn "Gateway $CFG_GW did not answer ping from $CFG_NODE2_HOST"
    info "Same-L2 connectivity between the two LXCs is verified once they are running"
  fi

  # Interactive runs already listened (and chose a free ID) at the VRRP question.
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    info "Listening 4s on $CFG_BRIDGE1 for existing VRRP traffic..."
    local vrids; vrids=$(vrrp_ids_in_use)   # excludes this deployment's own nodes
    if [[ "$vrids" == - ]]; then
      pf_warn "tcpdump not installed - cannot check for VRRP router id collisions"
    elif [[ " $vrids " == *" $CFG_VRID "* ]]; then
      pf_fail "VRRP router id $CFG_VRID is already used on this network (seen: $vrids)"
    else
      pf_ok "VRRP router id $CFG_VRID is available${vrids:+ (seen on network: $vrids)}"
    fi
  fi

  printf '  %sOther%s\n' "$C_BOLD" "$C_RESET"
  v_ssh_key "$CFG_SSH_KEY_FILE" && pf_ok "SSH key $CFG_SSH_KEY_FILE is valid" || pf_fail "SSH key $CFG_SSH_KEY_FILE invalid"

  for ip in $CFG_UPSTREAM_IPS; do
    doh_probe "$CFG_UPSTREAM_DOH_URL" "$ip" 2>/dev/null \
      && pf_ok "Upstream $CFG_UPSTREAM_DOH_URL answers via $ip" \
      || pf_fail "Upstream $CFG_UPSTREAM_DOH_URL did not answer a DoH query via $ip"
  done

  curl -fsS -m 10 -o /dev/null https://download.docker.com/linux/debian/gpg \
    && pf_ok "download.docker.com reachable" || pf_fail "Cannot reach download.docker.com"
  local code; code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null || true)
  [[ "$code" == 401 || "$code" == 200 ]] && pf_ok "Docker Hub registry reachable" || pf_fail "Cannot reach Docker Hub registry (HTTP $code)"
  curl -fsS -m 15 -o /dev/null "https://hub.docker.com/v2/repositories/technitium/dns-server/tags/$CFG_IMAGE_TAG" \
    && pf_ok "Image tag technitium/dns-server:$CFG_IMAGE_TAG exists" \
    || pf_fail "Image tag technitium/dns-server:$CFG_IMAGE_TAG not found on Docker Hub"

  if nodes_share_host; then
    pf_warn "Both DNS servers share this host: keepalived protects against container/service"
    pf_warn "failure, not against this host going down or rebooting."
  fi

  (( PF_FAIL == 0 )) || die "$PF_FAIL pre-flight check(s) failed - nothing has been changed"
  ok "All pre-flight checks passed"
}
