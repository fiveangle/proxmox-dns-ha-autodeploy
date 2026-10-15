# shellcheck shell=bash
# Base OS set-up + Docker CE inside each LXC.

# Script executed inside the container. Idempotent: safe to re-run.
bootstrap_script() {
  cat <<'EOF'
#!/bin/bash
set -Eeuo pipefail
LOG=/var/log/proxmox-dns-ha-autodeploy-bootstrap.log
trap 'echo "  bootstrap failed (line $LINENO); last log lines:"; tail -n 30 "$LOG"' ERR
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
step() { echo "  - $*"; }

# retry CMD... — up to 3 attempts, for flaky mirrors.
retry() {
  local i
  for i in 1 2 3; do
    "$@" >>"$LOG" 2>&1 && return 0
    echo "    attempt $i failed (exit $?), retrying in 5s"
    sleep 5
  done
  "$@" >>"$LOG" 2>&1
}

# apt 3.0 on trixie can balloon past 1 GB RSS (and be OOM-killed in a 1 GB container)
# when recovering failed pipelined HTTP downloads; reproduced in 3 of 5 fresh containers,
# 0 with pipelining off (normal peak ~220 MiB). Persisted so unattended-upgrades gets it too.
cat >/etc/apt/apt.conf.d/90proxmox-dns-ha-autodeploy <<'APTCONF'
Acquire::http::Pipeline-Depth "0";
Acquire::Retries "3";
APTCONF

dpkg --configure -a >>"$LOG" 2>&1   # recover from an interrupted earlier run

MARKER=/etc/proxmox-dns-ha-autodeploy/bootstrapped
step "apt update"
retry apt-get -q update
# Full upgrade only on the first bootstrap: a re-run of the deployment must not upgrade
# (and thereby restart) Docker/Technitium. Later updates come from unattended-upgrades.
if [[ ! -e "$MARKER" ]]; then
  step "full-upgrade (first bootstrap only)"
  retry "${APT[@]}" full-upgrade
fi

step "base packages (curl, jq, bind9-dnsutils, keepalived, ...)"
retry "${APT[@]}" install ca-certificates curl gnupg jq bind9-dnsutils keepalived iproute2 iputils-ping
# keepalived stays stopped until a later phase writes its configuration; never touch it
# once configured (that would drop the VIP on every re-run).
if ! grep -q 'proxmox-dns-ha-autodeploy' /etc/keepalived/keepalived.conf 2>/dev/null; then
  systemctl disable --now keepalived >>"$LOG" 2>&1 || true
fi

step "Docker CE apt repository"
. /etc/os-release
install -m 0755 -d /etc/apt/keyrings
retry curl -fsSL --retry 3 https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<SRC
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC
retry apt-get -q update

step "Docker CE + compose plugin"
retry "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker >>"$LOG" 2>&1

step "Docker self-test (hello-world)"
retry docker run --rm hello-world
docker image rm -f hello-world >>"$LOG" 2>&1 || true

# Packages the user asked for (arguments to this script). A failure here never fails the
# deployment: all at once first, then one by one to name the ones that cannot be installed.
if (( $# )); then
  step "extra packages: $*"
  if ! retry "${APT[@]}" install "$@"; then
    failed=""
    for p in "$@"; do "${APT[@]}" install "$p" >>"$LOG" 2>&1 || failed+=" $p"; done
    [[ -z "$failed" ]] || echo "  ! could not install:$failed (see $LOG)"
  fi
fi

echo "  - $(docker --version); $(docker compose version)"
echo "  - storage driver: $(docker info --format '{{.Driver}}')"
# Port 53 must be free, except for our own Technitium container on a re-run.
install -d -m 755 /etc/proxmox-dns-ha-autodeploy
touch "$MARKER"
if ss -lnup | grep -qE '[:.]53\s' && [[ -z "$(docker ps -q --filter name=^technitium$)" ]]; then
  echo "  ! something already listens on UDP 53:"; ss -lnup | grep -E '[:.]53\s'
  exit 1
fi
EOF
}

bootstrap_lxc() {
  local n=$1 tmp
  info "Bootstrapping $(node_var "$n" HOST): OS upgrade + Docker (log: /var/log/proxmox-dns-ha-autodeploy-bootstrap.log inside the LXC)"
  tmp=$(mktemp "$STATE_DIR/bootstrap.XXXXXX")
  bootstrap_script >"$tmp"
  lxc_push "$n" "$tmp" /root/technitium-bootstrap.sh 0700
  rm -f "$tmp"
  # shellcheck disable=SC2086  # word splitting intended: validated package names
  lxc_exec "$n" bash /root/technitium-bootstrap.sh ${CFG_EXTRA_PACKAGES:-}
  ok "$(node_var "$n" HOST): Docker ready"
}
