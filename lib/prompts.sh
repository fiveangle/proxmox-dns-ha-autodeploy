# shellcheck shell=bash
# Interactive questions, defaults detection, config load/save and summary.

# Every setting persisted to deploy.conf. The admin password is deliberately NOT here
# (it lives in $CREDENTIALS_FILE).
CONFIG_VARS=(
  CFG_NODE2_HOST CFG_TEMPLATE
  CFG_TEMPLATE_STORAGE1 CFG_TEMPLATE_STORAGE2 CFG_STORAGE1 CFG_STORAGE2
  CFG_BRIDGE1 CFG_BRIDGE2 CFG_VLAN1 CFG_VLAN2
  CFG_VMID1 CFG_VMID2 CFG_HOST1 CFG_HOST2 CFG_IP1 CFG_IP2 CFG_GW CFG_SEARCHDOMAIN
  CFG_CORES CFG_MEMORY CFG_SWAP CFG_DISK CFG_SSH_KEY_FILE CFG_TZ CFG_ONBOOT
  CFG_NS1 CFG_NS2 CFG_VIP CFG_VRID
  CFG_UPSTREAM_PRESET CFG_UPSTREAM_DOH_URL CFG_UPSTREAM_IPS
  CFG_ZONE CFG_ZONE_TYPE CFG_VIP_RECORD CFG_EXTRA_ZONES
  CFG_PTR_ZONE CFG_BLOCKLISTS CFG_BLOCKLIST_URLS CFG_WEB_HTTPS
  CFG_FIREWALL CFG_ADMIN_CIDR CFG_UNATTENDED CFG_EXTRA_PACKAGES
  CFG_SERVICE_DIR CFG_IMAGE_TAG
)

declare -A UPSTREAM_PRESET_URL=(
  [cloudflare]="https://cloudflare-dns.com/dns-query"
  [quad9]="https://dns.quad9.net/dns-query"
  [google]="https://dns.google/dns-query"
)
declare -A UPSTREAM_PRESET_IPS=(
  [cloudflare]="1.1.1.1 1.0.0.1"
  [quad9]="9.9.9.9 149.112.112.112"
  [google]="8.8.8.8 8.8.4.4"
)

BLOCKLIST_NAMES=("StevenBlack unified hosts" "OISD Big" "Hagezi Multi PRO")
BLOCKLIST_URLS=(
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
  "https://big.oisd.nl"
  "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt"
)

# ------------------------------------------------------- prompt helpers -----
# All prompts read from /dev/tty so the script works when stdout is tee'd.

# ask VAR "Question" "default" [validator] [error-message]
ask() {
  local __var=$1 q=$2 def=$3 validator=${4:-} emsg=${5:-"Invalid value"} ans
  [[ -n "${!__var:-}" ]] && def=${!__var}
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "$(printf '%s?%s %s [%s]: ' "$C_BOLD" "$C_RESET" "$q" "$def")" ans </dev/tty
    else
      read -r -p "$(printf '%s?%s %s: ' "$C_BOLD" "$C_RESET" "$q")" ans </dev/tty
    fi
    ans=${ans:-$def}
    if [[ -z "$validator" ]] || "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      return 0
    fi
    warn "$emsg"
  done
}

# ask_optional — like ask, but an empty answer is accepted. Enter "-" to clear a default.
ask_optional() {
  local __var=$1 q=$2 def=$3 validator=${4:-} emsg=${5:-"Invalid value"} ans
  [[ -n "${!__var+x}" ]] && def=${!__var}
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "$(printf '%s?%s %s [%s] ("-" = none): ' "$C_BOLD" "$C_RESET" "$q" "$def")" ans </dev/tty
    else
      read -r -p "$(printf '%s?%s %s (optional, Enter = none): ' "$C_BOLD" "$C_RESET" "$q")" ans </dev/tty
    fi
    [[ -z "$ans" ]] && ans=$def
    [[ "$ans" == "-" ]] && ans=""
    if [[ -z "$ans" || -z "$validator" ]] || "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      return 0
    fi
    warn "$emsg"
  done
}

# ask_yn VAR "Question" yes|no  -> stores yes/no
ask_yn() {
  local __var=$1 q=$2 def=$3 ans hint
  [[ -n "${!__var:-}" ]] && def=${!__var}
  [[ "$def" == yes ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "$(printf '%s?%s %s [%s]: ' "$C_BOLD" "$C_RESET" "$q" "$hint")" ans </dev/tty
    case "${ans,,}" in
      "")      printf -v "$__var" '%s' "$def"; return 0 ;;
      y|yes)   printf -v "$__var" yes; return 0 ;;
      n|no)    printf -v "$__var" no;  return 0 ;;
      *)       warn "Please answer y or n" ;;
    esac
  done
}

# ask_choice VAR "Question" default key1 "label1" key2 "label2" ...
ask_choice() {
  local __var=$1 q=$2 def=$3; shift 3
  local -a keys=() labels=(); local i ans defnum=1
  [[ -n "${!__var:-}" ]] && def=${!__var}
  while (( $# )); do keys+=("$1"); labels+=("$2"); shift 2; done
  printf '%s?%s %s\n' "$C_BOLD" "$C_RESET" "$q"
  for i in "${!keys[@]}"; do
    [[ "${keys[$i]}" == "$def" ]] && defnum=$((i+1))
    printf '    %d) %s\n' $((i+1)) "${labels[$i]}"
  done
  while true; do
    read -r -p "  Choice [$defnum]: " ans </dev/tty
    ans=${ans:-$defnum}
    if int_between "$ans" 1 "${#keys[@]}"; then
      printf -v "$__var" '%s' "${keys[$((ans-1))]}"
      return 0
    fi
    warn "Enter a number between 1 and ${#keys[@]}"
  done
}

# ------------------------------------------------------------ detection -----
# Node-aware detection helpers take the node number (1|2) as first argument.
# Validators that depend on a node read PROMPT_NODE.
PROMPT_NODE=1

detect_bridge()      { node_exec "$1" ip -br link show type bridge 2>/dev/null | awk '$1 ~ /^vmbr/ {print $1; exit}'; }
detect_bridge_cidr() { node_exec "$1" ip -4 -o addr show dev "$2" 2>/dev/null | awk '{print $4; exit}'; }
detect_gateway()     { ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }
detect_tz()      { timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Etc/UTC; }
detect_searchdomain() { awk '/^search/ {print $2; exit}' /etc/resolv.conf 2>/dev/null; }

detect_ssh_key() {
  local f
  for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_ecdsa.pub /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys; do
    [[ -s "$f" ]] && { echo "$f"; return; }
  done
  return 0
}

template_storages() { node_exec "$1" pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'; }

# choose_template_storage N — set CFG_TEMPLATE_STORAGE<N> with as few questions as possible:
# a storage that already holds the template is used silently (the saved choice first), a single
# template storage is used silently, and only a choice between several is asked.
choose_template_storage() {
  local n=$1 var="CFG_TEMPLATE_STORAGE$1" saved s def
  local -a stores
  saved=${!var:-}
  mapfile -t stores < <(template_storages "$n")
  (( ${#stores[@]} )) || die "$(node_label "$n") has no active storage for CT templates (Datacenter -> Storage -> Content)"
  for s in ${saved:+"$saved"} "${stores[@]}"; do
    [[ " ${stores[*]} " == *" $s "* ]] || continue
    if node_exec "$n" pveam list "$s" 2>/dev/null | grep -qF "vztmpl/$CFG_TEMPLATE"; then
      printf -v "$var" '%s' "$s"; return 0
    fi
  done
  if (( ${#stores[@]} == 1 )); then printf -v "$var" '%s' "${stores[0]}"; return 0; fi
  def=$saved; [[ " ${stores[*]} " == *" $def "* ]] || def=""
  [[ -n "$def" ]] || def=$(printf '%s\n' "${stores[@]}" | grep -x local || echo "${stores[0]}")
  printf -v "$var" '%s' "$def"
  info "Template storages on $(node_label "$n"): ${stores[*]}"
  ask "$var" "Save $CFG_TEMPLATE on $(node_label "$n") to" "$def" v_tmpl_storage "Choose one of: ${stores[*]}"
}

# resolve_template — CFG_TEMPLATE = the newest debian-13-standard amd64 template in Proxmox's
# catalog (refreshed first), never an older locally cached one. Only when the catalog cannot be
# fetched is the newest local copy used, with a warning. ensure_template downloads it if needed.
resolve_template() {
  local re='^debian-13-standard_.*_amd64\.tar\.(zst|gz|xz)$' latest="" old=${CFG_TEMPLATE:-} s
  if node_exec 1 pveam update >/dev/null 2>&1; then
    latest=$(node_exec 1 pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "$re" | sort -V | tail -1 || true)
  fi
  if [[ -z "$latest" ]]; then
    latest=$(for s in $(template_storages 1); do node_exec 1 pveam list "$s" 2>/dev/null; done \
      | awk 'NR>1 {sub(/.*\//, "", $1); print $1}' | grep -E "$re" | sort -V | tail -1 || true)
    [[ -n "$latest" ]] || die "Cannot reach the Proxmox template catalog (pveam update) and no Debian 13 template is cached"
    warn "Template catalog unreachable - using the newest cached template $latest (may not be the latest release)"
    CFG_TEMPLATE=$latest; return 0
  fi
  CFG_TEMPLATE=$latest
  if [[ -n "$old" && "$old" != "$latest" ]]; then
    info "Debian 13 template: $latest (newer than the saved $old)"
  else
    info "Debian 13 template: $latest (latest)"
  fi
}

# choose_rootdir_storage N — CFG_STORAGE<N>: the only container-disk storage silently, otherwise
# a question listing them (default: saved choice, then local-zfs, then the first one).
choose_rootdir_storage() {
  local n=$1 var="CFG_STORAGE$1" def
  local -a stores
  mapfile -t stores < <(rootdir_storages "$n")
  (( ${#stores[@]} )) || die "$(node_label "$n") has no active storage for container disks (Datacenter -> Storage -> Content)"
  if (( ${#stores[@]} == 1 )); then printf -v "$var" '%s' "${stores[0]}"; return 0; fi
  def=${!var:-}; [[ " ${stores[*]} " == *" $def "* ]] || def=""
  [[ -n "$def" ]] || def=$(printf '%s\n' "${stores[@]}" | grep -x local-zfs || echo "${stores[0]}")
  printf -v "$var" '%s' "$def"
  info "Container disk storages on $(node_label "$n"): ${stores[*]}"
  ask "$var" "Storage for $(node_var "$n" HOST)'s root disk" "$def" v_storage "Choose one of: ${stores[*]}"
}

# vrrp_ids_in_use — VRRP router IDs advertised on node 1's bridge during a 4s listen, excluding
# this deployment's own nodes (a re-deploy). Prints "-" when tcpdump is not available.
vrrp_ids_in_use() {
  node_exec 1 sh -c 'command -v tcpdump' >/dev/null 2>&1 || { echo -; return 0; }
  node_exec 1 timeout 4 tcpdump -lnni "$CFG_BRIDGE1" -c 500 '(ip proto 112) or (vlan and ip proto 112)' 2>/dev/null \
    | awk -v a="${CFG_IP1%/*}" -v b="${CFG_IP2%/*}" '
        { src = ""; for (i = 1; i < NF; i++) if ($i == "IP") { src = $(i+1); break } }
        src == a || src == b { next }
        match($0, /vrid [0-9]+/) { print substr($0, RSTART + 5, RLENGTH - 5) }' | sort -un | paste -sd' ' || true
}

# prompt_vrid — the VRRP router ID only has to differ from other VRRP groups on the LAN (routers,
# firewalls, other keepalived pairs), so the default is a number nobody was heard using.
prompt_vrid() {
  local used def
  info "Checking $CFG_BRIDGE1 for VRRP routers already on this LAN (4s)"
  used=$(vrrp_ids_in_use)
  printf '  %sThe two servers use VRRP to decide which one holds %s; the ID only has to differ
' "$C_DIM" "$CFG_VIP"
  if [[ "$used" == - ]]; then
    printf '  from other VRRP devices on this LAN (not checked: tcpdump is not installed).%s
' "$C_RESET"
    used=""
  elif [[ -n "$used" ]]; then
    printf '  from other VRRP devices on this LAN. Already in use here: %s%s
' "$used" "$C_RESET"
  else
    printf '  from other VRRP devices on this LAN. None were heard, so any number 1-255 works.%s
' "$C_RESET"
  fi
  VRID_IN_USE=" $used "
  def=${CFG_VRID:-}
  if [[ -z "$def" || "$VRID_IN_USE" == *" $def "* ]]; then
    CFG_VRID=""
    def=$(( (RANDOM % 200) + 20 ))
    while [[ "$VRID_IN_USE" == *" $def "* ]]; do def=$(( (def % 255) + 1 )); done
  fi
  ask CFG_VRID "VRRP virtual router ID" "$def" v_vrid_free "1-255 and not one of:$VRID_IN_USE"
}
v_vrid_free() { v_vrid "$1" && [[ "${VRID_IN_USE:- }" != *" $1 "* ]]; }

rootdir_storages() { node_exec "$1" pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'; }

used_vmids() { node_exec "$1" pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid'; }

# next_free_vmid N [after] — first free VMID on node N's host >= its nextid (and > after)
next_free_vmid() {
  local id used
  id=$(node_exec "$1" pvesh get /cluster/nextid 2>/dev/null || echo 100)
  used=" $(used_vmids "$1" | tr '\n' ' ') "
  [[ -n "${2:-}" ]] && (( id <= $2 )) && id=$(( $2 + 1 ))
  while [[ "$used" == *" $id "* ]]; do id=$((id+1)); done
  echo "$id"
}

# Newest stable X.Y.Z tag of technitium/dns-server on Docker Hub.
latest_technitium_tag() {
  curl -fsS -m 15 'https://hub.docker.com/v2/repositories/technitium/dns-server/tags?page_size=100&ordering=last_updated' 2>/dev/null \
    | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1 || true
}

# ----------------------------------------------------------- validators -----
v_vmid()      { int_between "$1" 100 999999999; }
v_cores()     { int_between "$1" 1 64; }
v_memory()    { int_between "$1" 512 65536; }
v_swap()      { int_between "$1" 0 65536; }
v_disk()      { int_between "$1" 4 1024; }
v_vlan()      { int_between "$1" 1 4094; }
v_vrid()      { int_between "$1" 1 255; }
v_bridge()    { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] && node_exec "$PROMPT_NODE" ip link show "$1" >/dev/null 2>&1; }
v_storage()   { rootdir_storages "$PROMPT_NODE" | grep -qx "$1"; }
v_tmpl_storage() { template_storages "$PROMPT_NODE" | grep -qx "$1"; }
v_remote_host() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; }
v_ssh_key()   { [[ -s "$1" ]] && ssh-keygen -l -f "$1" >/dev/null 2>&1; }
v_tz()        { [[ -e "/usr/share/zoneinfo/$1" ]]; }
v_abs_path()  { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != "/" ]]; }
v_tag()       { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
v_ip_in_net() { is_ipv4 "$1" && ip_in_cidr "$1" "$(cidr_network "$CFG_IP1")"; }
v_cidr_in_net() { is_ipv4_cidr "$1" && [[ "${1#*/}" == "${CFG_IP1#*/}" ]] && v_ip_in_net "${1%/*}"; }
v_ip_list()   { local i; for i in $1; do is_ipv4 "$i" || return 1; done; [[ -n "$1" ]]; }
v_any_cidr()  { [[ "$1" == */* ]] && is_ipv4 "${1%/*}" && int_between "${1#*/}" 0 32; }
# Extra zones: valid, distinct names that are not the main or reverse zone.
# Warns with the exact reason for the first bad name.
v_extra_zones() {
  local z seen=" " rz=""
  [[ -n "$CFG_ZONE" && "$CFG_PTR_ZONE" == yes ]] && rz=$(reverse_zone_for "$CFG_IP1")
  for z in $1; do
    if ! is_domain "$z"; then warn "'$z' is not a valid domain name"; return 1; fi
    if [[ "$z" == "$CFG_ZONE" ]]; then warn "$z is already the main zone"; return 1; fi
    if [[ -n "$rz" && "$z" == "$rz" ]]; then warn "$z is already the reverse zone"; return 1; fi
    if [[ "$seen" == *" $z "* ]]; then warn "$z is listed twice"; return 1; fi
    seen+="$z "
  done
}
v_extra_zones_input() { v_extra_zones "$(normalize_zones "$1")"; }
# normalize_zones "A., b;c" -> "a b c" (lower case, no trailing dots; commas, semicolons or
# spaces between names)
normalize_zones() { local z out="" in=${1,,}; for z in ${in//[,;]/ }; do out+="${z%.} "; done; echo "${out% }"; }
# Extra apt packages: valid Debian package names; on a Debian 13 host they must also exist in
# its apt index (PVE 9 is trixie-based, so its index matches the LXCs').
is_pkg_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; }
v_packages() {
  local p unknown=""
  set -- "$(normalize_list "$1")"
  for p in $1; do is_pkg_name "$p" || { warn "Not a valid package name: $p"; return 1; }; done
  if [[ "$(. /etc/os-release && echo "$VERSION_CODENAME")" == trixie ]]; then
    for p in $1; do apt-cache show --no-all-versions "$p" >/dev/null 2>&1 || unknown+=" $p"; done
    [[ -z "$unknown" ]] || { warn "Not found in the Debian 13 package index:$unknown"; return 1; }
  fi
}
normalize_list() { local in=${1,,}; in=${in//[,;]/ }; echo $in; }   # "A, b;c" -> "a b c"
v_packages_list() { local p; for p in $1; do is_pkg_name "$p" || return 1; done; }
v_blocklist_sel() { local n; for n in ${1//,/ }; do int_between "$n" 1 "${#BLOCKLIST_URLS[@]}" || return 1; done; [[ -n "$1" ]]; }

# ---------------------------------------------------------- the questions ---
prompt_all() {
  local def

  section "Proxmox hosts"
  info "Node 1 always runs on this host ($(hostname -s)). Node 2 can run here too, or on a"
  info "separate Proxmox VE host on the same network/VLAN so a host reboot never stops DNS."
  local where=local
  [[ -n "${CFG_NODE2_HOST:-}" ]] && where=remote
  ask_choice where "Where should node 2 run?" "$where" \
    local  "This host ($(hostname -s))" \
    remote "Another Proxmox VE host (reached over root SSH)"
  if [[ "$where" == remote ]]; then
    ask CFG_NODE2_HOST "Hostname or IP of the second Proxmox VE host" "" v_remote_host "Invalid hostname/IP"
    ensure_node2_ssh
  else
    CFG_NODE2_HOST=""
  fi

  section "LXC settings"
  ask CFG_HOST1 "Hostname of LXC #1" "dns1" is_hostname "Invalid hostname"
  ask CFG_HOST2 "Hostname of LXC #2" "dns2" is_hostname "Invalid hostname"
  [[ "$CFG_HOST1" != "$CFG_HOST2" ]] || die "LXC hostnames must differ"

  resolve_template

  local n host vmid_def
  for n in 1 2; do
    PROMPT_NODE=$n
    host=$(node_var "$n" HOST)
    printf '\n  %sNode %s: %s on %s%s\n' "$C_BOLD" "$n" "$host" "$(node_label "$n")" "$C_RESET"
    if [[ "$n" == 2 ]] && nodes_share_host; then
      vmid_def=$(next_free_vmid 2 "$CFG_VMID1")
    else
      vmid_def=$(next_free_vmid "$n")
    fi
    ask "CFG_VMID$n" "VMID for $host" "$vmid_def" v_vmid "VMID must be an integer >= 100"

    if [[ "$n" == 2 ]] && nodes_share_host; then
      # Same host: reuse node 1's host-level choices.
      CFG_TEMPLATE_STORAGE2=$CFG_TEMPLATE_STORAGE1; CFG_STORAGE2=$CFG_STORAGE1
      CFG_BRIDGE2=$CFG_BRIDGE1; CFG_VLAN2=$CFG_VLAN1
      continue
    fi
    choose_template_storage "$n"
    choose_rootdir_storage "$n"
    ask "CFG_BRIDGE$n" "Network bridge for $host" "$(detect_bridge "$n")" v_bridge "Bridge does not exist on that host"
    ask_optional "CFG_VLAN$n" "VLAN tag for $host" "" v_vlan "VLAN must be 1-4094"
  done
  PROMPT_NODE=1
  if nodes_share_host; then
    [[ "$CFG_VMID1" != "$CFG_VMID2" ]] || die "VMIDs must differ on the same host"
  elif [[ "$CFG_VLAN1" != "$CFG_VLAN2" ]]; then
    warn "Different VLAN tags per node: the VIP only works if both end up on the same L2 network"
  fi

  local bridge_cidr; bridge_cidr=$(detect_bridge_cidr 1 "$CFG_BRIDGE1")
  [[ -n "$bridge_cidr" && -z "$CFG_VLAN1" ]] && info "Host network on $CFG_BRIDGE1: $(cidr_network "$bridge_cidr")"
  ask CFG_IP1 "Static IP/prefix for $CFG_HOST1 (e.g. 192.168.1.11/24)" "" is_ipv4_cidr "Use CIDR form, e.g. 192.168.1.11/24"
  ask CFG_IP2 "Static IP/prefix for $CFG_HOST2" "" v_cidr_in_net "Must be CIDR, same prefix and subnet as $CFG_HOST1"
  [[ "${CFG_IP1%/*}" != "${CFG_IP2%/*}" ]] || die "LXC IPs must differ"
  def=$(detect_gateway); v_ip_in_net "$def" 2>/dev/null || def=""
  ask CFG_GW "Default gateway" "$def" v_ip_in_net "Gateway must be an IPv4 address inside $(cidr_network "$CFG_IP1")"

  ask CFG_CORES  "CPU cores per LXC" "2" v_cores "1-64"
  ask CFG_MEMORY "RAM per LXC (MB)" "1024" v_memory "512-65536 (Docker + Technitium need >= 512)"
  ask CFG_SWAP   "Swap per LXC (MB)" "512" v_swap "0-65536"
  ask CFG_DISK   "Root disk per LXC (GB)" "8" v_disk "4-1024"

  ask CFG_SSH_KEY_FILE "SSH public key file to install for root" "$(detect_ssh_key)" v_ssh_key "File missing or not a valid public key"
  ask CFG_TZ "Timezone" "$(detect_tz)" v_tz "Unknown timezone (see /usr/share/zoneinfo)"
  ask_yn CFG_ONBOOT "Start LXCs automatically when the host boots?" yes

  section "DNS / high-availability settings"
  ask CFG_NS1 "Technitium server name on $CFG_HOST1" "ns1" is_hostname "Invalid hostname label"
  ask CFG_NS2 "Technitium server name on $CFG_HOST2" "ns2" is_hostname "Invalid hostname label"
  [[ "$CFG_NS1" != "$CFG_NS2" ]] || die "Technitium server names must differ"

  ask CFG_VIP "Virtual IP (floats between the two servers)" "" v_ip_in_net "Must be an IPv4 address inside $(cidr_network "$CFG_IP1")"
  [[ "$CFG_VIP" != "${CFG_IP1%/*}" && "$CFG_VIP" != "${CFG_IP2%/*}" && "$CFG_VIP" != "$CFG_GW" ]] \
    || die "The VIP must differ from both LXC IPs and the gateway"
  prompt_vrid

  ask_choice CFG_UPSTREAM_PRESET "Upstream DNS-over-HTTPS provider" cloudflare \
    cloudflare "Cloudflare  (1.1.1.1, 1.0.0.1)" \
    quad9      "Quad9       (9.9.9.9, 149.112.112.112) - malware filtering" \
    google     "Google      (8.8.8.8, 8.8.4.4)" \
    custom     "Custom DoH endpoint"
  if [[ "$CFG_UPSTREAM_PRESET" == custom ]]; then
    ask CFG_UPSTREAM_DOH_URL "DoH URL (e.g. https://dns.example/dns-query)" "" is_https_url "Must be an https:// URL"
    ask CFG_UPSTREAM_IPS "Bootstrap IPv4 address(es) of that server, space-separated" "" v_ip_list "Space-separated IPv4 addresses"
  else
    CFG_UPSTREAM_DOH_URL=${UPSTREAM_PRESET_URL[$CFG_UPSTREAM_PRESET]}
    CFG_UPSTREAM_IPS=${UPSTREAM_PRESET_IPS[$CFG_UPSTREAM_PRESET]}
  fi

  section "Local zone"
  ask_optional CFG_ZONE "Local DNS zone name (e.g. home.example.com, home.arpa)" "" is_domain "Invalid domain name"
  CFG_ZONE=${CFG_ZONE%.}; CFG_ZONE=${CFG_ZONE,,}
  if [[ -n "$CFG_ZONE" ]]; then
    cat <<EOF
  ${C_DIM}If $CFG_ZONE is a real public domain you own, a Conditional Forwarder zone is created:
  records you add are answered locally; names NOT in the zone are forwarded upstream.
  For a private-only name (home.arpa, lan, ...) a Primary zone is created instead:
  names not in the zone return NXDOMAIN.${C_RESET}
EOF
    def=yes
    [[ "$CFG_ZONE" =~ (^|\.)(home\.arpa|lan|local|internal|localdomain|intranet|corp|home|private)$ ]] && def=no
    local public=""; [[ -n "${CFG_ZONE_TYPE:-}" ]] && { [[ "$CFG_ZONE_TYPE" == forwarder ]] && public=yes || public=no; }
    [[ -n "$public" ]] || public=$def
    ask_yn public "Is $CFG_ZONE a public domain you own?" "$public"
    [[ "$public" == yes ]] && CFG_ZONE_TYPE=forwarder || CFG_ZONE_TYPE=primary
    ask_optional CFG_VIP_RECORD "Extra host name in $CFG_ZONE pointing at the VIP" "dns" is_hostname "Invalid hostname label"
    ask_yn CFG_PTR_ZONE "Create reverse (PTR) zone $(reverse_zone_for "$CFG_IP1")?" no
  else
    CFG_ZONE_TYPE=""; CFG_VIP_RECORD=""; CFG_PTR_ZONE=no
  fi
  cat <<EOF
  ${C_DIM}Additional zones work like a Conditional Forwarder zone: records you add on $CFG_NS1 are
  answered locally (and copied to $CFG_NS2); names not in the zone are forwarded upstream.
  More can be added later with helpers/zones.sh add <zone>.${C_RESET}
EOF
  ask_optional CFG_EXTRA_ZONES "Additional local zones (e.g. example.net, example.org)" "" v_extra_zones_input \
    "Please re-enter the list"
  CFG_EXTRA_ZONES=$(normalize_zones "$CFG_EXTRA_ZONES")
  ask CFG_SEARCHDOMAIN "DNS search domain for the LXCs" "${CFG_ZONE:-$(detect_searchdomain)}" is_domain "Invalid domain"

  section "Optional features"
  ask_yn CFG_BLOCKLISTS "Enable ad/malware blocklists?" no
  if [[ "$CFG_BLOCKLISTS" == yes ]]; then
    local i sel n defsel=1
    for i in "${!BLOCKLIST_NAMES[@]}"; do printf '    %d) %s\n' $((i+1)) "${BLOCKLIST_NAMES[$i]}"; done
    ask sel "Which lists (comma-separated numbers)" "$defsel" v_blocklist_sel "e.g. 1 or 1,3"
    CFG_BLOCKLIST_URLS=""
    for n in ${sel//,/ }; do CFG_BLOCKLIST_URLS+="${BLOCKLIST_URLS[$((n-1))]} "; done
    CFG_BLOCKLIST_URLS=${CFG_BLOCKLIST_URLS% }
  else
    CFG_BLOCKLIST_URLS=""
  fi
  ask_yn CFG_WEB_HTTPS "Enable HTTPS for the web UI (self-signed cert, port 53443)?" yes
  ask_yn CFG_FIREWALL "Enable Proxmox firewall rules for both LXCs?" no
  if [[ "$CFG_FIREWALL" == yes ]]; then
    ask CFG_ADMIN_CIDR "Network allowed to reach SSH and the web UI" "$(cidr_network "$CFG_IP1")" v_any_cidr "CIDR, e.g. 192.168.1.0/24"
  else
    CFG_ADMIN_CIDR=""
  fi
  ask_yn CFG_UNATTENDED "Enable unattended security upgrades inside the LXCs?" yes
  printf '  %se.g. tmux btop htop vim ncdu mtr-tiny tcpdump rsync%s\n' "$C_DIM" "$C_RESET"
  ask_optional CFG_EXTRA_PACKAGES "Extra apt packages to install in both LXCs" "" \
    v_packages "Fix or remove the package names above"
  CFG_EXTRA_PACKAGES=$(normalize_list "$CFG_EXTRA_PACKAGES")

  section "Technitium container"
  ask CFG_SERVICE_DIR "Service directory inside each LXC (compose.yaml + data/)" "/srv/technitium" v_abs_path "Absolute path, no spaces"
  CFG_SERVICE_DIR=${CFG_SERVICE_DIR%/}
  def=$(latest_technitium_tag); [[ -n "$def" ]] || { warn "Could not query Docker Hub for the latest tag"; def=""; }
  [[ "${CFG_IMAGE_TAG:-}" == latest ]] && CFG_IMAGE_TAG=""   # never offer a floating tag as the default
  ask CFG_IMAGE_TAG "technitium/dns-server image tag to pin" "$def" v_pinned_tag \
    "Use a version number${def:+ (e.g. $def)}; update later with helpers/update.sh"
}

# A version tag, not "latest": a floating tag lets any re-run upgrade both servers at once,
# bypassing update.sh's one-node-at-a-time upgrade and rollback.
v_pinned_tag() {
  v_tag "$1" || return 1
  if [[ "${1,,}" == latest ]]; then
    warn "'latest' would let a re-run upgrade both servers at once, skipping the safe rolling update"
    return 1
  fi
}

_v_template() { [[ "$1" =~ ^debian-13-standard_.*_amd64\.tar\.(zst|gz|xz)$ ]]; }

# ---------------------------------------------------- admin password --------
# Sets ADMIN_PASSWORD. Reuses the saved credential if one exists and the user agrees.
prompt_admin_password() {
  local p1 p2 reuse
  section "Technitium admin password"
  if [[ -s "$CREDENTIALS_FILE" ]] && grep -q '^ADMIN_PASSWORD=' "$CREDENTIALS_FILE"; then
    reuse=yes
    if [[ "${NONINTERACTIVE:-0}" != 1 ]]; then
      ask_yn reuse "Use the admin password saved in $CREDENTIALS_FILE?" yes
    fi
    if [[ "$reuse" == yes ]]; then
      ADMIN_PASSWORD=$(sed -n 's/^ADMIN_PASSWORD=//p' "$CREDENTIALS_FILE" | head -1)
      ADMIN_PASSWORD=${ADMIN_PASSWORD#\'}; ADMIN_PASSWORD=${ADMIN_PASSWORD%\'}
      ok "Using saved admin password"
      return
    fi
  fi
  [[ "${NONINTERACTIVE:-0}" == 1 ]] && die "No saved admin password in $CREDENTIALS_FILE; run interactively once"

  while true; do
    read -r -s -p "$(printf '%s?%s Admin password (min 8 chars; Enter = generate one): ' "$C_BOLD" "$C_RESET")" p1 </dev/tty; echo
    if [[ -z "$p1" ]]; then
      p1=$(rand_alnum 24)
      printf '\n  Generated password:  %s%s%s\n' "$C_BOLD$C_YELLOW" "$p1" "$C_RESET"
      printf '  It will also be saved to %s (root-only).\n' "$CREDENTIALS_FILE"
      while true; do
        read -r -p "  Type it back to confirm you have a copy: " p2 </dev/tty
        [[ "$p2" == "$p1" ]] && break
        warn "Does not match - try again (or Ctrl+C to abort)"
      done
      clear_screen_hint
      break
    fi
    (( ${#p1} >= 8 )) || { warn "Too short"; continue; }
    [[ "$p1" != *[\'\"\\\$\`]* ]] || { warn "Avoid quotes, backslash, \$ and backtick"; continue; }
    read -r -s -p "  Repeat password: " p2 </dev/tty; echo
    [[ "$p1" == "$p2" ]] && break
    warn "Passwords do not match"
  done
  ADMIN_PASSWORD=$p1
}

clear_screen_hint() { printf '  %s(Tip: clear your terminal scrollback if others can see this screen.)%s\n' "$C_DIM" "$C_RESET"; }

# cred_get KEY -> value saved in $CREDENTIALS_FILE (empty if absent)
cred_get() { sed -n "s/^$1='\(.*\)'\$/\1/p" "$CREDENTIALS_FILE" 2>/dev/null | head -1; }

# VRRP PASS authentication secret (keepalived uses at most 8 characters). Generated once,
# then reused so both nodes and every re-run agree.
ensure_vrrp_secret() {
  VRRP_AUTH_PASS=$(cred_get VRRP_AUTH_PASS)
  [[ -n "$VRRP_AUTH_PASS" ]] || VRRP_AUTH_PASS=$(rand_alnum 8)
}

save_credentials() {
  [[ "$DRY_RUN" == 1 ]] && { info "[dry-run] would save credentials to $CREDENTIALS_FILE"; return; }
  install -d -m 700 "$STATE_DIR"
  ( umask 077
    printf "ADMIN_USER='admin'\nADMIN_PASSWORD='%s'\nVRRP_AUTH_PASS='%s'\n" "$ADMIN_PASSWORD" "$VRRP_AUTH_PASS" \
      >"$CREDENTIALS_FILE.tmp"
    mv "$CREDENTIALS_FILE.tmp" "$CREDENTIALS_FILE" )
  ok "Credentials saved to $CREDENTIALS_FILE (mode 600)"
}

# --------------------------------------------------------- config file ------
save_config() {
  local f=${1:-$CONFIG_FILE_DEFAULT} v
  install -d -m 700 "$(dirname "$f")"
  {
    echo "# Technitium HA deployment answers - generated $(date -Is)"
    echo "# Re-run without questions: deploy.sh --config $f"
    for v in "${CONFIG_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v:-}"; done
  } >"$f.tmp"
  chmod 600 "$f.tmp"; mv "$f.tmp" "$f"
  ok "Answers saved to $f"
}

load_config() {
  local f=$1 line
  [[ -f "$f" ]] || die "Config file not found: $f"
  [[ "$(stat -c %u "$f")" == 0 ]] || die "Config $f must be owned by root"
  (( ( 8#$(stat -c %a "$f") & 8#022 ) == 0 )) || die "Config $f must not be group/world-writable"
  # Accept only KEY=value lines for known keys, so a stray command can never execute.
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^(CFG_[A-Z0-9_]+)= ]] || die "Unexpected line in $f: $line"
    [[ " ${CONFIG_VARS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || die "Unknown setting in $f: ${BASH_REMATCH[1]}"
  done <"$f"
  # shellcheck disable=SC1090
  source "$f"
  : "${CFG_EXTRA_ZONES:=}" "${CFG_EXTRA_PACKAGES:=}"   # added after the first release; older files lack them
  ok "Loaded answers from $f"
}

# Validate every value (used for --config runs, where no prompt validated them).
validate_config() {
  local errs=0
  _chk() { "$2" "${!1:-}" || { err "Invalid $1='${!1:-}'"; errs=$((errs+1)); }; }
  _chk CFG_TEMPLATE _v_template
  [[ -z "$CFG_NODE2_HOST" ]] || _chk CFG_NODE2_HOST v_remote_host
  local n
  for n in 1 2; do
    PROMPT_NODE=$n
    _chk "CFG_TEMPLATE_STORAGE$n" v_tmpl_storage; _chk "CFG_STORAGE$n" v_storage; _chk "CFG_BRIDGE$n" v_bridge
    [[ -z "$(node_var "$n" VLAN)" ]] || _chk "CFG_VLAN$n" v_vlan
  done
  PROMPT_NODE=1
  _chk CFG_VMID1 v_vmid; _chk CFG_VMID2 v_vmid; _chk CFG_HOST1 is_hostname; _chk CFG_HOST2 is_hostname
  _chk CFG_IP1 is_ipv4_cidr; _chk CFG_IP2 v_cidr_in_net; _chk CFG_GW v_ip_in_net
  _chk CFG_CORES v_cores; _chk CFG_MEMORY v_memory; _chk CFG_SWAP v_swap; _chk CFG_DISK v_disk
  _chk CFG_SSH_KEY_FILE v_ssh_key; _chk CFG_TZ v_tz; _chk CFG_SEARCHDOMAIN is_domain
  _chk CFG_NS1 is_hostname; _chk CFG_NS2 is_hostname; _chk CFG_VIP v_ip_in_net; _chk CFG_VRID v_vrid
  _chk CFG_UPSTREAM_DOH_URL is_https_url; _chk CFG_UPSTREAM_IPS v_ip_list
  if [[ -n "$CFG_ZONE" ]]; then
    _chk CFG_ZONE is_domain
    [[ "$CFG_ZONE_TYPE" == forwarder || "$CFG_ZONE_TYPE" == primary ]] || { err "CFG_ZONE_TYPE must be forwarder|primary"; errs=$((errs+1)); }
    [[ -z "$CFG_VIP_RECORD" ]] || _chk CFG_VIP_RECORD is_hostname
  fi
  [[ -z "$CFG_EXTRA_ZONES" ]] || _chk CFG_EXTRA_ZONES v_extra_zones
  [[ -z "$CFG_EXTRA_PACKAGES" ]] || _chk CFG_EXTRA_PACKAGES v_packages_list
  [[ "$CFG_FIREWALL" != yes ]] || _chk CFG_ADMIN_CIDR v_any_cidr
  _chk CFG_SERVICE_DIR v_abs_path; _chk CFG_IMAGE_TAG v_tag
  [[ "${CFG_IMAGE_TAG,,}" != latest ]] \
    || warn "CFG_IMAGE_TAG=latest: a re-run may upgrade both servers at once - pin a version (helpers/update.sh <version>)"
  local v; for v in CFG_ONBOOT CFG_PTR_ZONE CFG_BLOCKLISTS CFG_WEB_HTTPS CFG_FIREWALL CFG_UNATTENDED; do
    [[ "${!v}" == yes || "${!v}" == no ]] || { err "$v must be yes|no"; errs=$((errs+1)); }
  done
  [[ "$CFG_HOST1" != "$CFG_HOST2" && "$CFG_NS1" != "$CFG_NS2" ]] \
    || { err "Hostnames and server names must differ between nodes"; errs=$((errs+1)); }
  if nodes_share_host && [[ "$CFG_VMID1" == "$CFG_VMID2" ]]; then
    err "VMIDs must differ when both nodes are on the same host"; errs=$((errs+1))
  fi
  (( errs == 0 )) || die "$errs invalid setting(s) in config"
  ok "Configuration valid"
}

# ------------------------------------------------------------- summary ------
print_summary() {
  local zone_desc="none (forwarding-only resolver)"
  if [[ -n "$CFG_ZONE" ]]; then
    zone_desc="$CFG_ZONE ($([[ $CFG_ZONE_TYPE == forwarder ]] && echo 'Conditional Forwarder: missing names go upstream' || echo 'Primary: missing names = NXDOMAIN'))"
  fi
  section "Summary"
  cat <<EOF
  ${C_BOLD}Node              #1                        #2${C_RESET}
  Proxmox host      $(printf '%-25s %s' "$(node_label 1)" "$(node_label 2)")
  LXC hostname      $(printf '%-25s %s' "$CFG_HOST1" "$CFG_HOST2")
  VMID              $(printf '%-25s %s' "$CFG_VMID1" "$CFG_VMID2")
  IP                $(printf '%-25s %s' "$CFG_IP1" "$CFG_IP2")
  Technitium name   $(printf '%-25s %s' "$CFG_NS1" "$CFG_NS2")
  Keepalived role   $(printf '%-25s %s' "MASTER (priority 150)" "BACKUP (priority 100)")
  Bridge / VLAN     $(printf '%-25s %s' "$CFG_BRIDGE1 / ${CFG_VLAN1:-untagged}" "$CFG_BRIDGE2 / ${CFG_VLAN2:-untagged}")
  Root disk storage $(printf '%-25s %s' "$CFG_STORAGE1" "$CFG_STORAGE2")
  Template file at  $(printf '%-25s %s' "$CFG_TEMPLATE_STORAGE1" "$CFG_TEMPLATE_STORAGE2")

  Virtual IP        $CFG_VIP   (VRRP router id $CFG_VRID, failback after 60s)
  Gateway           $CFG_GW
  Template          $CFG_TEMPLATE
  Resources (each)  ${CFG_CORES} cores, ${CFG_MEMORY} MB RAM, ${CFG_SWAP} MB swap, ${CFG_DISK} GB disk
  SSH key           $CFG_SSH_KEY_FILE
  Timezone          $CFG_TZ      Start on boot: $CFG_ONBOOT
  Search domain     $CFG_SEARCHDOMAIN

  Upstream (DoH)    $CFG_UPSTREAM_DOH_URL  via ${CFG_UPSTREAM_IPS// /, }
  Local zone        $zone_desc
  VIP record        $([[ -n "$CFG_VIP_RECORD" ]] && echo "$CFG_VIP_RECORD.$CFG_ZONE -> $CFG_VIP" || echo none)
  Reverse zone      $([[ $CFG_PTR_ZONE == yes ]] && reverse_zone_for "$CFG_IP1" || echo no)
  Extra zones       ${CFG_EXTRA_ZONES:-none}$([[ -n $CFG_EXTRA_ZONES ]] && echo '  (Conditional Forwarder: missing names go upstream)')
  Blocklists        ${CFG_BLOCKLIST_URLS:-no}
  Web UI            $([[ $CFG_WEB_HTTPS == yes ]] && echo "https://<node-ip>:53443 (self-signed)" || echo "http://<node-ip>:5380")
  PVE firewall      $CFG_FIREWALL${CFG_ADMIN_CIDR:+ (admin access from $CFG_ADMIN_CIDR)}
  Unattended upgr.  $CFG_UNATTENDED
  Extra packages    ${CFG_EXTRA_PACKAGES:-none}
  Service dir       $CFG_SERVICE_DIR   (compose.yaml, data/config -> /etc/dns)
  Image             technitium/dns-server:$CFG_IMAGE_TAG
EOF
}
