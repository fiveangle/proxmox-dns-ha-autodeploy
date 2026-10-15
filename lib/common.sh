# shellcheck shell=bash
# Common helpers: logging, error handling, command execution, validation.

STATE_DIR="${STATE_DIR:-/root/proxmox-dns-ha-autodeploy}"
PROJECT_URL="https://github.com/fiveangle/proxmox-dns-ha-autodeploy"
CONFIG_FILE_DEFAULT="$STATE_DIR/deploy.conf"
CREDENTIALS_FILE="$STATE_DIR/credentials"
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=
fi

info()    { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

# Start mirroring all output to a timestamped log file in STATE_DIR.
start_logging() {
  install -d -m 700 "$STATE_DIR"
  LOG_FILE="$STATE_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
  ( umask 077; : >"$LOG_FILE" )
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Logging to $LOG_FILE"
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]} cmd=$BASH_COMMAND
  err "Command failed (exit $rc) at line $line: $cmd"
  [[ -n "${LOG_FILE:-}" ]] && err "See log: $LOG_FILE"
  exit "$rc"
}

# run CMD...  — execute, or just print it in dry-run mode.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s[DRY]%s   %s\n' "$C_DIM" "$C_RESET" "$(printf '%q ' "$@")"
  else
    "$@"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# ------------------------------------------------------------- validation ---
is_int()      { [[ "$1" =~ ^[0-9]+$ ]]; }
int_between() { is_int "$1" && (( 10#$1 >= $2 && 10#$1 <= $3 )); }

is_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

is_ipv4_cidr() {
  [[ "$1" == */* ]] || return 1
  is_ipv4 "${1%/*}" && int_between "${1#*/}" 8 30
}

# RFC 1123 hostname label (no dots).
is_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

# DNS zone / domain name (at least one dot not required: "lan" and "home.arpa" both valid).
is_domain() {
  local d=${1%.}
  [[ ${#d} -le 253 && "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

is_https_url() { [[ "$1" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]; }

# ------------------------------------------------------------ IPv4 maths ----
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
prefix2mask() { echo $(( (0xFFFFFFFF << (32-$1)) & 0xFFFFFFFF )); }

# cidr_network 192.168.1.11/24 -> 192.168.1.0/24
cidr_network() {
  local ip=${1%/*} p=${1#*/}
  echo "$(int2ip $(( $(ip2int "$ip") & $(prefix2mask "$p") )))/$p"
}

# ip_in_cidr IP NET/PREFIX
ip_in_cidr() {
  local net=${2%/*} p=${2#*/} m
  m=$(prefix2mask "$p")
  (( ($(ip2int "$1") & m) == ($(ip2int "$net") & m) ))
}

# Reverse zone name for the octet-aligned network containing CIDR (prefix rounded down to /24, /16, /8).
reverse_zone_for() {
  local ip=${1%/*} p=${1#*/} a b c
  IFS=. read -r a b c _ <<<"$ip"
  if   (( p >= 24 )); then echo "$c.$b.$a.in-addr.arpa"
  elif (( p >= 16 )); then echo "$b.$a.in-addr.arpa"
  else                     echo "$a.in-addr.arpa"
  fi
}

# Random alphanumeric string of length N (no shell/URL-special characters).
# Reads a fixed amount of randomness, so no pipe is ever cut short (no SIGPIPE under pipefail
# or an inherited ERR trap).
rand_alnum() {
  local n=${1:-24} s=""
  while (( ${#s} < n )); do s+=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9'); done
  echo "${s:0:n}"
}
