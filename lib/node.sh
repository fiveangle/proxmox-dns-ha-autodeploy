# shellcheck shell=bash
# Node abstraction: node 1 always runs on this PVE host; node 2 runs either here or on
# a separate (non-clustered) PVE host reached over root SSH. Every Proxmox command goes
# through these wrappers so the rest of the code never cares where a node lives.

# KNOWN_HOSTS / SSH_IDENTITY may be set in the environment (e.g. to use a dedicated key).
KNOWN_HOSTS=${KNOWN_HOSTS:-/root/.ssh/known_hosts}
SSH_OPTS=(
  -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o ControlMaster=auto -o "ControlPath=/root/.ssh/pdha-%C" -o ControlPersist=120
)
if [[ -n "${SSH_IDENTITY:-}" ]]; then SSH_OPTS+=(-o IdentitiesOnly=yes -i "$SSH_IDENTITY"); fi

# node_host N -> remote hostname for node N, or empty when node N is this host.
node_host() { [[ "$1" == 2 ]] && echo "${CFG_NODE2_HOST:-}" || true; }
node_is_remote() { [[ -n "$(node_host "$1")" ]]; }
node_label() { node_is_remote "$1" && echo "$(node_host "$1")" || echo "$(hostname -s) (local)"; }
nodes_share_host() { ! node_is_remote 2; }

# node_var N NAME -> value of CFG_<NAME><N>, e.g. node_var 2 IP -> $CFG_IP2
node_var() { local v="CFG_$2$1"; echo "${!v:-}"; }

# node_exec N CMD... — always executes (used for read-only queries, even in dry-run).
node_exec() {
  local n=$1; shift
  if node_is_remote "$n"; then
    ssh "${SSH_OPTS[@]}" "root@$(node_host "$n")" -- "$(printf '%q ' "$@")"
  else
    "$@"
  fi
}

# node_run N CMD... — like node_exec but only printed in dry-run mode.
node_run() {
  local n=$1; shift
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s[DRY]%s   %s%s\n' "$C_DIM" "$C_RESET" \
      "$(node_is_remote "$n" && echo "[ssh $(node_host "$n")] ")" "$(printf '%q ' "$@")"
  else
    node_exec "$n" "$@"
  fi
}

# node_copy N LOCAL_FILE REMOTE_PATH — copy a file onto node N's PVE host.
node_copy() {
  local n=$1 src=$2 dst=$3
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s[DRY]%s   copy %s -> %s:%s\n' "$C_DIM" "$C_RESET" "$src" "$(node_label "$n")" "$dst"
  elif node_is_remote "$n"; then
    scp -q "${SSH_OPTS[@]}" "$src" "root@$(node_host "$n"):$dst"
  else
    install -m 600 "$src" "$dst"
  fi
}

# ---------------------------------------------------------- inside an LXC ---
# pct exec passes the host's locale (e.g. LANG=en_US.UTF-8) into the container, where it is
# usually not generated; C.UTF-8 always exists on Debian and keeps perl/apt tools quiet.
LXC_ENV=(env LANG=C.UTF-8 LC_ALL=C.UTF-8)

# lxc_exec N CMD...  — run a command inside node N's container.
lxc_exec() { local n=$1; shift; node_run "$n" pct exec "$(node_var "$n" VMID)" -- "${LXC_ENV[@]}" "$@"; }

# lxc_query N CMD... — same, but executes even in dry-run (read-only checks).
lxc_query() { local n=$1; shift; node_exec "$n" pct exec "$(node_var "$n" VMID)" -- "${LXC_ENV[@]}" "$@"; }

# lxc_push N LOCAL_FILE DEST [PERMS] — copy a local file into node N's container.
lxc_push() {
  local n=$1 src=$2 dst=$3 perms=${4:-0644} vmid tmp
  vmid=$(node_var "$n" VMID)
  if node_is_remote "$n"; then
    tmp="/tmp/proxmox-dns-ha-autodeploy.$$.$RANDOM"
    node_copy "$n" "$src" "$tmp"
    node_run "$n" pct push "$vmid" "$tmp" "$dst" --perms "$perms"
    node_run "$n" rm -f "$tmp"
  else
    node_run "$n" pct push "$vmid" "$src" "$dst" --perms "$perms"
  fi
}

# --------------------------------------------------------- SSH set-up -------
local_pubkey() {
  local f
  [[ -n "${SSH_IDENTITY:-}" && -s "$SSH_IDENTITY.pub" ]] && { echo "$SSH_IDENTITY.pub"; return 0; }
  for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_ecdsa.pub /root/.ssh/id_rsa.pub; do
    [[ -s "$f" ]] && { echo "$f"; return 0; }
  done
  return 0
}

# Make sure root SSH to node 2's host works non-interactively; offer to fix it if not.
ensure_node2_ssh() {
  local host=$CFG_NODE2_HOST answer key fp scanned
  install -d -m 700 "$STATE_DIR" /root/.ssh

  # 1. Host key: pin it after the user confirms the fingerprint. Scan once, so the keys
  #    written to known_hosts are exactly the ones whose fingerprints were approved.
  if ! ssh-keygen -F "$host" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    [[ "${NONINTERACTIVE:-0}" == 1 ]] && die "Host key for $host is not in $KNOWN_HOSTS; run interactively once"
    scanned=$(ssh-keyscan -T 5 "$host" 2>/dev/null | grep -v '^#' || true)
    [[ -n "$scanned" ]] || die "Cannot reach SSH on $host"
    fp=$(ssh-keygen -lf - <<<"$scanned")
    printf '  Host key fingerprints offered by %s:\n%s\n' "$host" "$(sed 's/^/    /' <<<"$fp")"
    answer=""
    ask_yn answer "Trust this host key? (compare with: ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub on $host)" no
    [[ "$answer" == yes ]] || die "Host key not trusted"
    printf '%s\n' "$scanned" >>"$KNOWN_HOSTS"
    ok "Pinned host key for $host"
  fi

  # 2. Key-based login.
  if ! ssh "${SSH_OPTS[@]}" "root@$host" true 2>/dev/null; then
    [[ "${NONINTERACTIVE:-0}" == 1 ]] && die "Key-based root SSH to $host failed; run: ssh-copy-id root@$host"
    warn "Key-based root SSH to $host does not work yet"
    key=$(local_pubkey)
    if [[ -z "$key" ]]; then
      answer=""
      ask_yn answer "No SSH key on this host. Generate /root/.ssh/id_ed25519 now?" yes
      [[ "$answer" == yes ]] || die "An SSH key is needed to manage $host"
      ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C "root@$(hostname -s) proxmox-dns-ha-autodeploy"
      key=/root/.ssh/id_ed25519.pub
    fi
    answer=""
    ask_yn answer "Install $key on $host with ssh-copy-id (asks for $host's root password once)?" yes
    [[ "$answer" == yes ]] || die "Set up key-based SSH to root@$host and re-run"
    ssh-copy-id -i "$key" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" "root@$host" </dev/tty
    ssh "${SSH_OPTS[@]}" "root@$host" true || die "Key-based SSH to $host still fails"
  fi
  ok "Root SSH to $host works"

  # 3. Must be a different Proxmox VE host.
  node_exec 2 test -d /etc/pve || die "$host is not a Proxmox VE host"
  if [[ "$(node_exec 2 cat /etc/machine-id)" == "$(cat /etc/machine-id)" ]]; then
    die "$host is this same machine - choose 'this host' for node 2 instead"
  fi
  ok "$host is Proxmox VE: $(node_exec 2 pveversion | head -1)"
}
