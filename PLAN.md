# Technitium DNS HA on Proxmox — Project Plan

Two unprivileged Debian 13 LXCs on Proxmox VE, each running Docker + Technitium DNS
(via docker compose, bind mounts only) and native keepalived managing a single
floating VIP.

## 1. Decisions (locked)

| Area | Decision | Rationale |
|---|---|---|
| Tooling | Single interactive **bash script run on the PVE host** (`pct`/`pveam`), answers saved to a re-runnable `.conf` | No extra tooling; reproducible |
| Node placement | **Deploy-time choice**: node 2 on this host (default) or on a **separate, non-clustered PVE host** over root SSH. All PVE commands go through `node_exec`/`node_run`/`lxc_exec`/`lxc_push` (lib/node.sh). VMID, bridge and VLAN are asked per node. The template is always the newest debian-13-standard in the refreshed catalog (downloaded if missing; a cached copy only if the catalog is unreachable, with a warning). Template storage and root-disk storage are picked automatically when only one fits (template storage: wherever the template already is) and asked with the options listed otherwise | Survives PVE host reboots/upgrades |
| Host-to-host SSH | Script tests key auth; if missing, shows + pins the host key after confirmation and offers `ssh-copy-id` | Needed only during deployment |
| Same-L2 requirement | After both LXCs start, node 1 must ARP node 2's real MAC; deployment stops otherwise | A VIP can't float across a router |
| LXC type | **Unprivileged**, `nesting=1,keyctl=1` | Docker + keepalived both work; container root ≠ host root |
| Keepalived | **Native apt package** (systemd) in each LXC | Survives Docker restarts/crashes; releases VIP cleanly; no stale-VIP risk |
| Technitium net | **`network_mode: host`** | Serves on VIP as soon as it appears; real client IPs; no NAT |
| VIP | **One VIP, active/standby** | dns1 normally MASTER |
| Failback | **preempt_delay 60s** | VIP returns to dns1 only after it has been healthy for 60s |
| Zone type | **Asked at deploy time**: public domain you own → *Conditional Forwarder* zone (local records answered, missing names forwarded upstream); private name → *Primary* zone | A Primary zone returns NXDOMAIN for missing hosts and never forwards |
| Zone sync | **ns1 Primary → ns2 Secondary** (zone transfer + NOTIFY, restricted to node IPs) | Standard and proven; edit on ns1 only |
| Upstream | **DNS-over-HTTPS**, presets Cloudflare / Quad9 / Google / custom | Port 443, rarely blocked |
| Service dir | **`/srv/technitium`** (prompt, overridable) | FHS: admin-owned, site-specific service data; packages never write there |
| Image/updates | **Pinned tag** + bundled **rolling `update.sh`** | Controlled upgrades; BACKUP first, then MASTER |
| LXC access | **SSH public key** injected; `pct enter` from host | No password SSH |
| Admin password | **Prompt or generate** (generated must be typed back); saved to `/root/proxmox-dns-ha-autodeploy/credentials` (600) on PVE host; verified by API login; removed from LXC `.env` after first boot; `reset-admin.sh` provided | Never locked out |
| LXC resolv.conf | **Upstream IPs during build → `127.0.0.1` + upstream fallback once healthy** | No bootstrap chicken-and-egg |
| Deploy-time y/N prompts | Zone type, PTR zone, blocklists, PVE firewall, unattended-upgrades, web UI HTTPS | User decides per deployment |

## 2. Project file layout

```
proxmox-dns-ha-autodeploy/
├── deploy.sh                    # main entry point (interactive or --config file)
├── lib/
│   ├── common.sh                # logging, colours, error trap, validation helpers
│   ├── prompts.sh               # all questions, defaults, validation, summary
│   ├── node.sh                  # local/remote node abstraction + SSH set-up
│   ├── preflight.sh             # per-host / conflict checks; resume detection
│   ├── lxc.sh                   # template download, pct create/start/exec/push
│   ├── docker.sh                # OS upgrade + Docker CE (official repo), with apt retries
│   ├── technitium.sh            # compose render + REST API configuration
│   └── keepalived.sh            # config + health-check render
├── templates/
│   ├── compose.yaml.tmpl
│   ├── keepalived.conf.tmpl
│   └── check_technitium.sh
├── helpers/                     # pushed into each LXC at /srv/technitium/bin/
│   ├── update.sh                # rolling upgrade (run on PVE host, drives both)
│   ├── reset-admin.sh           # admin password recovery
│   ├── status.sh                # who holds VIP, health, zone serials
│   └── zones.sh                 # list / add / remove additional local zones
├── deploy.conf.example
└── PLAN.md
```

PVE host state: `/root/proxmox-dns-ha-autodeploy/` → `deploy.conf`, `credentials` (600), `deploy-<timestamp>.log`.

## 3. Prompt flow (defaults shown; detected where possible)

**Proxmox / LXC**
1. Template — newest `debian-13-standard` (auto `pveam update` + download if not cached; currently 13.6)
2. Rootfs storage — `local-zfs` (list of storages that support `rootdir`)
3. Bridge — `vmbr0`; optional VLAN tag
4. VMIDs — next free IDs (`pvesh get /cluster/nextid`), editable
5. LXC hostnames — `dns1`, `dns2` (warn on existing CT name)
6. Static IPs (CIDR) — e.g. `192.168.1.11/24`, `192.168.1.12/24`; gateway auto-detected (e.g. `192.168.1.1`)
7. Cores `2`, RAM `1024` MB, swap `512` MB, disk `8` GB
8. DNS search domain (defaults to local zone name if given)
9. SSH public key file — `/root/.ssh/id_ed25519.pub` (or `authorized_keys`)
10. Timezone — copied from host
11. Start on boot `yes`; startup order (dns1 before dns2)

**DNS / HA**
12. Technitium server names — `ns1`, `ns2`
13. VIP — e.g. `192.168.1.10` (must be in same subnet, unused)
14. VRRP virtual_router_id — random 1–255 (warn: must be unique on the LAN)
15. Upstream preset — Cloudflare DoH (`https://cloudflare-dns.com/dns-query` with IPs 1.1.1.1, 1.0.0.1) / Quad9 / Google / custom
16. Local zone name — optional (blank = forwarding-only resolver)
17. → If zone given: "Is this a public domain you own?" (Y → Conditional Forwarder, N → Primary)
18. → Optional extra A record for the VIP (e.g. `dns.<zone>`)
19. Reverse PTR zone? y/N (derived from subnet)
19a. Additional local zones (optional, space-separated) - Conditional Forwarder, as below
20. Blocklists? y/N → choose lists (StevenBlack, OISD, Hagezi…)
21. Web UI HTTPS (self-signed, :53443)? Y/n
22. Proxmox firewall rules? y/N → LAN CIDR for UI/SSH access
22a. Extra apt packages for both LXCs (optional; examples shown: tmux btop htop vim ncdu mtr-tiny
     tcpdump rsync). Names are checked against the host's Debian 13 apt index at the prompt;
     installed in the bootstrap after Docker. An uninstallable package is reported, never fatal.
     Re-runs install newly added packages; removing a name does not uninstall it.
23. Unattended security upgrades? y/N
24. Service directory — `/srv/technitium`
25. Technitium image tag — latest stable resolved from Docker Hub, pinned
26. Admin password — enter, or Enter to generate (must re-type)

→ Full summary table → confirm → write `deploy.conf` → deploy.
`./deploy.sh --config /root/proxmox-dns-ha-autodeploy/deploy.conf` re-runs without questions.

## 4. Pre-flight checks (abort before touching anything)

- Running as root on a PVE node; `pct`, `pveam`, `pvesh` present
- VMIDs free; hostnames unique (warn) ; IPs + VIP unused (`arping`/`ping`), same subnet, not equal
- Storage active and supports `rootdir`; enough free space
- SSH key file exists and is valid (`ssh-keygen -l -f`)
- Upstream reachable from host (curl the DoH endpoint)
- Warning banner: both LXCs on one physical host → protects against container/service failure, not host failure

## 5. Provisioning (per LXC; dns1 then dns2, steps idempotent where feasible)

1. `pct create <id> <template> --hostname --cores --memory --swap --rootfs <storage>:<size>
   --net0 name=eth0,bridge=,ip=,gw=,firewall=1[,tag=] --nameserver "<upstream IPs>"
   --searchdomain --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1
   --startup order=N --ssh-public-keys <file> --timezone <tz> --tags dns;technitium`
2. `pct start`, wait for network
3. `apt update && full-upgrade`; install `ca-certificates curl gnupg jq dnsutils keepalived iproute2`
4. Docker CE from Docker's official apt repo (trixie) — `docker-ce docker-ce-cli containerd.io docker-compose-plugin`; enable service; confirm `overlay2` storage driver
5. Ensure nothing else holds port 53
6. Optional: unattended-upgrades (security origin only)

## 6. Technitium deployment

`/srv/technitium/compose.yaml` (rendered):
```yaml
services:
  technitium:
    image: technitium/dns-server:<pinned>
    container_name: technitium
    hostname: ns1                      # ns2 on node 2
    network_mode: host
    restart: unless-stopped
    env_file: .env
    volumes:
      - /srv/technitium/data/config:/etc/dns
    sysctls: {}                        # host netns; none needed
    stop_grace_period: 30s
```
`.env` (600): `DNS_SERVER_DOMAIN=ns1.<zone>`, `DNS_SERVER_ADMIN_PASSWORD=…` (removed after first boot),
recursion/forwarder env vars where supported. All data under `data/` — no named volumes.

**API configuration** (script, via `pct exec … curl http://127.0.0.1:5380/api/…`):
1. Login → session token
2. Settings: forwarders = upstream DoH, forwarder protocol HTTPS; recursion = private networks only;
   DNSSEC validation on; serve-stale on; query logging (local) on
3. Zone (if given):
   - ns1: create Primary *or* Conditional Forwarder zone; zone transfer allowed to ns2 IP only; NOTIFY ns2
   - records: `ns1` → node1 IP, `ns2` → node2 IP, NS set to ns1/ns2, optional `dns` → VIP
   - ns2: create Secondary (or Secondary Forwarder) zone with primary = ns1 IP
4. Optional PTR zone (same primary/secondary pattern), PTRs for ns1, ns2, VIP
5. Optional blocklists (both nodes), optional HTTPS self-signed cert
6. Verify: API login with saved password on both nodes; remove password from `.env`

## 7. Keepalived

`/etc/keepalived/keepalived.conf` (dns1 shown; dns2 priority 100):
```
global_defs {
  router_id dns1
  enable_script_security
  script_user keepalived_script
}
vrrp_script chk_technitium {
  script "/etc/keepalived/check_technitium.sh"
  interval 1
  timeout 2
  fall 2
  rise 3
}
vrrp_instance VI_DNS {
  state BACKUP                 # both BACKUP so preempt_delay works
  interface eth0
  virtual_router_id <id>
  priority 150
  advert_int 1
  preempt_delay 60
  unicast_src_ip <self>
  unicast_peer { <peer> }
  authentication { auth_type PASS  auth_pass <random8> }
  virtual_ipaddress { <VIP>/<prefix> dev eth0 }
  track_script { chk_technitium }
  garp_master_delay 1
  garp_master_refresh 30
  notify "/etc/keepalived/notify.sh"   # logs transitions to journal
}
```
`check_technitium.sh`: `dig +time=1 +tries=1 @127.0.0.1 localhost A` (or the zone SOA). It tests the
**local** service only, so an upstream internet outage does not cause flapping.

Expected failover ≤ ~3 s (advert 1s × 3 + skew, or 2 failed checks).

## 8. Finalisation

- Switch each LXC's resolv.conf → `127.0.0.1`, upstream as fallback (`pct set --nameserver`)
- Optional PVE firewall: per-CT rules — allow 53/udp+tcp from LAN, 5380/53443 from admin CIDR,
  22 from admin CIDR, VRRP (proto 112) between node IPs, policy_in DROP
- Push helpers to `/srv/technitium/bin/`; copy `update.sh` / `status.sh` on host
- **Validation suite** (printed pass/fail):
  - `dig @VIP`, `@node1`, `@node2` for external name (e.g. `debian.org`) and DNSSEC-signed name
  - local record via VIP; missing local host behaves per zone type
  - zone SOA serial equal on ns1/ns2
  - VIP present on exactly one node
  - Optional live failover test: stop Technitium on MASTER, time until VIP answers, restore
- Final report: IPs, VIP, UI URLs, credentials file path, next steps
  (point DHCP/clients at the VIP; retire the old DNS server when ready)

## 9. Helpers

- Helpers reach the LXCs **directly over SSH** (key injected at creation), so they work the
  same for single- and two-host deployments; host-to-host root SSH can be removed afterwards.
- **update.sh** `[tag]` — resolve target tag → update BACKUP node (pull, up -d, wait healthy) →
  update MASTER (VIP fails over to updated node) → after preempt_delay VIP returns to dns1; reports
- **reset-admin.sh** — compose down, move `auth.config` aside, start with temp password, prompt new
- **status.sh** — VIP holder, keepalived state, container health, image tag, zone serials
  (from the API, for every managed zone; a mismatch is re-checked once after 12 s)
- **zones.sh** `list | add ZONE... | remove ZONE [--yes]` — additional local zones
  (`CFG_EXTRA_ZONES`). Each is a Conditional Forwarder zone on ns1 (`forwarder=this-server`:
  records answered locally, names not in the zone forwarded upstream) with a `SecondaryForwarder`
  copy on ns2, transfer + NOTIFY locked to ns2. `add` adopts an existing Forwarder zone on ns1
  (e.g. made in the web UI), refuses other zone types, then proves the path: a temporary TXT on
  ns1 must be answered by both servers and an unknown name must get the upstream rcode.
  `remove` exports the zone file to `zone-backups/` first. deploy.sh re-runs keep the zones.

## 10. Risks / items to verify during implementation

1. **UDP source address on VIP**: with a wildcard bind, replies to queries sent to the VIP must
   come *from* the VIP. Test this; if Technitium does not preserve it, bind explicitly to
   node IP + VIP + 127.0.0.1 and set `net.ipv4.ip_nonlocal_bind=1` in the LXC.
   Observed: Technitium opens a per-address UDP socket (`<node-ip>:53`) besides the
   wildcard. ✅ Verified: it binds the VIP within ~3 s of keepalived adding it at runtime and
   replies come from the VIP; no ip_nonlocal_bind needed.
9. Fixed during phase 4: `keepalived --config-test=X` treats X as a LOG file (it appended its
   output into the config); now `keepalived -t -l -f FILE`, any output = failure. Bootstrap
   re-runs no longer stop keepalived (VIP outage) or full-upgrade (Docker restart).
10. Health check queries `localhost A` (answered authoritatively by Technitium's built-in zone),
   so an upstream/internet outage cannot put both nodes in FAULT and drop the VIP.
2. ✅ Verified against v15.6.1: env vars, /api/user/login, settings/set, zones/create,
   zones/options/set, records/add (ptr=true), zones/resync. Users live in data/config/auth.config.
3. ✅ Conditional Forwarder + `SecondaryForwarder` tested end-to-end with a real public domain.
4. ✅ Corrected: deleting `auth.config` crashes v15 on start (zone permissions live there; found
   when the first reset-admin.sh version took dns2 down - restored from its backup). The
   supported way is renaming it to `resetadmin.config`: Technitium keeps all users/permissions/
   tokens and resets only admin to "admin"; reset-admin.sh then sets the new password at once.
5. VRRP router ID must not collide with any other VRRP/keepalived on the LAN.
6. Single physical host (when chosen): both nodes fail together if that host goes down.
7. Existing guest names on the host(s) are checked — the script warns on clashes.
8. apt 3.0 (trixie) can balloon past 1 GB and be OOM-killed while recovering failed pipelined
   HTTP downloads: 3 of 5 fresh containers with defaults, 0 of 2 with pipelining off (normal
   peak ~220 MiB). Fixed by persisting `Acquire::http::Pipeline-Depth "0"` + `Acquire::Retries "3"`
   in /etc/apt/apt.conf.d/90proxmox-dns-ha-autodeploy (also covers unattended-upgrades) plus 3x step
   retries. RAM default stays 1024 MB.

## 11. Implementation phases

1. ✅ `lib/common.sh`, `prompts.sh`, `preflight.sh` + dry-run mode (`--dry-run` prints actions)
2. ✅ Two-host node abstraction; LXC creation, same-L2 check, Docker install; resumable re-runs
3. ✅ Technitium compose + API configuration (tested: primary + PTR zones, two hosts, idempotent re-runs)
4. ✅ Keepalived + health check. Measured on the two-host test (probe every 0.2s on the VIP):
   | Scenario | Longest DNS outage |
   |---|---|
   | Full deployment re-run | 0 s (0 of 416 probes failed) |
   | Technitium stopped on MASTER | 2.7 s (failover to node 2) |
   | Technitium back -> failback after 60 s | 0 s |
   | Docker daemon restart on MASTER | 1.3 s (recovered before the 2 s health threshold; no failover) |
   | keepalived stopped gracefully / failback | 1.2 s / seamless |
   | MASTER LXC shut down / started (failback) | 1.2 s / seamless |
   | BACKUP LXC on other host shut down | 0 s |
5. ✅ Optional extras, verified on a fresh two-host deployment of a public domain (Conditional
   Forwarder) with every option on:
   - Forwarder zone: local records answered; `www.<zone>` (not in zone) = upstream answer.
     ns2 syncs via `SecondaryForwarder`.
   - ns1 -> ns2 record propagation: 10.3 s for add/change/delete (Technitium's NOTIFY delay);
     SOA refresh (15 min) is the fallback if a NOTIFY is missed.
   - Blocklists: v15 blocks with NXDOMAIN + EDE 15 "Blocked" (not 0.0.0.0).
   - HTTPS UI on 53443 (self-signed), HTTP 5380 -> 307 redirect; API/healthcheck follow it.
   - Unattended upgrades: Debian-Security origins only (Docker repo excluded), timers 03:30/05:30.
   - PVE firewall: enforced on the first host; failover/failback with it on showed no split brain.
     On a host whose datacenter firewall is off rules are written but not enforced;
     the script warns and never enables the datacenter firewall itself.
6. ✅ Finalisation + helpers:
   - LXC resolver -> 127.0.0.1, upstream fallback; SSH host keys of the LXCs pinned via `pct exec`.
   - Built-in live failover test (`--failover-test`, or asked interactively): 2.7 s failover,
     0 s failback, never both nodes holding the VIP.
   - `helpers/status.sh` (exit 1 on any problem), `helpers/update.sh [tag]` (tested 15.6.1 -> 15.6.0
     -> 15.6.1: max 0.9 s VIP impact; updates deploy.conf; auto-rollback path untested),
     `helpers/reset-admin.sh [1|2|all]`, `helpers/failover-test.sh` - all over direct SSH.
7. ✅ End-to-end tests on two separate, non-clustered Proxmox VE 9 hosts
8. ✅ Additional zones (`helpers/zones.sh`, `CFG_EXTRA_ZONES`), tested live on two hosts:
   - add: zone on ns1 + SecondaryForwarder on ns2 in ~11 s including the end-to-end check;
     re-add is a no-op; main zone and invalid names are refused.
   - adopt: Forwarder zone with an A record created on ns1 only -> `list` reports it unmanaged,
     `add` creates the ns2 copy; the record answered by ns2 and the VIP.
   - full deploy.sh re-run with two extra zones: no serial changes, all checks passed.
   - remove: zone file exported, deleted on ns2 then ns1, config updated.
   - Found + fixed: rand_alnum SIGPIPE noise under the inherited ERR trap; config writes must not
     pass %q output through `awk -v` (it strips the backslashes).
