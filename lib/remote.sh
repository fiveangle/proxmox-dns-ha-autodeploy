# shellcheck shell=bash
# SSH transport for the helper scripts: talk to the LXCs directly at their own IPs (using the
# key injected at creation) instead of through each Proxmox host's `pct exec`. Sourcing this
# after node.sh replaces lxc_exec / lxc_query / lxc_push, so every other library function
# works unchanged whether the nodes share a host or not.

LXC_SSH_OPTS=(
  -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o ControlMaster=auto -o "ControlPath=/root/.ssh/pdha-%C" -o ControlPersist=60
)
# Prefer the private key matching the public key installed in the LXCs.
if [[ -n "${CFG_SSH_KEY_FILE:-}" && -r "${CFG_SSH_KEY_FILE%.pub}" ]]; then
  LXC_SSH_OPTS+=(-i "${CFG_SSH_KEY_FILE%.pub}")
fi

lxc_ssh() {
  local n=$1; shift
  ssh "${LXC_SSH_OPTS[@]}" "root@$(node_ip "$n")" -- "$(printf '%q ' "${LXC_ENV[@]}" "$@")"
}

lxc_query() { lxc_ssh "$@"; }

lxc_exec() {
  local n=$1; shift
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s[DRY]%s   [ssh %s] %s\n' "$C_DIM" "$C_RESET" "$(node_ip "$n")" "$(printf '%q ' "$@")"
  else
    lxc_ssh "$n" "$@"
  fi
}

lxc_push() {
  local n=$1 src=$2 dst=$3 perms=${4:-0644}
  [[ "$DRY_RUN" == 1 ]] && { printf '%s[DRY]%s   scp %s -> %s:%s\n' "$C_DIM" "$C_RESET" "$src" "$(node_ip "$n")" "$dst"; return; }
  scp -q "${LXC_SSH_OPTS[@]}" "$src" "root@$(node_ip "$n"):$dst"
  lxc_ssh "$n" chmod "$perms" "$dst"
}
