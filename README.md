# proxmox-dns-ha-autodeploy

**From an empty Proxmox host to a redundant, tested DNS pair - with one command.**

`deploy.sh` creates two Debian 13 LXCs (or up to four, see [More secondaries](#more-secondaries)), installs Docker and
[Technitium DNS Server](https://technitium.com/dns/), puts a floating virtual IP in front of them
with keepalived, syncs your zones between them, and verifies the whole thing - including a live
failover test. No Proxmox cluster required, and nothing to set up by hand: give clients the one
VIP, and if a server goes down the other answers within seconds.

Answer a short series of questions (each with a sensible default), or re-run it unattended from
a saved answers file.

## Highlights

- **Fast, verified failover** - typical DNS outage on the VIP of **~3 s** when the active server
  fails, and **0 s** when it comes back (failback waits 60 s for it to be fully ready, then hands
  over seamlessly). A live failover test can run at the end of every deployment.
- **Survives a host failure** - place the second server on a **separate, non-clustered Proxmox
  host** over SSH; the script handles the key exchange, per-host storage and network choices.
- **Up to three secondaries, if you want them** - a pair is the default; ask for 2 or 3
  secondaries and the VIP has more servers to fail over to, each on this host or another one.
- **Zero-downtime upgrades** - `helpers/update.sh` upgrades Technitium one node at a time, the
  VIP holder last: before it is touched, the VIP is handed to an already-upgraded node the
  seamless way (like a failback; measured **0 s** on the VIP), and handed back afterwards.
  `deploy.sh` re-runs do the same when they upgrade Docker or keepalived. Each LXC is
  snapshotted first, and a node whose new version is not healthy is rolled back to that
  snapshot automatically, program and data.
- **Local zones that never break the internet** - records you add are answered locally; names not
  in the zone are forwarded upstream, so a public domain you own keeps working for every host you
  have not defined. Add more zones any time with `helpers/zones.sh`.
- **Your DHCP clients by name** - optionally forward a LAN subdomain (e.g. `lan.example.com`)
  and reverse lookups to your router/DHCP server, so `laptop.lan.example.com` resolves through
  the VIP while everything else keeps using encrypted DNS. Toggle it any time with `helpers/lan.sh`.
- **Edit once, served twice** - changes made on ns1 reach ns2 automatically in ~10 s via zone
  transfer (locked to the two servers). Optional reverse (PTR) zone included.
- **Private, validated upstream** - DNS-over-HTTPS to Cloudflare, Quad9 or Google (or your own),
  DNSSEC validation, serve-stale, recursion limited to private networks.
- **Health-checked, not just alive** - keepalived moves the VIP when Technitium stops *answering*,
  not only when the LXC dies; no split brain (both nodes never hold the VIP at once).
- **Optional extras, chosen at deploy time** - ad/malware blocklists, HTTPS web UI, Proxmox
  firewall rules, unattended security upgrades, extra apt packages (tmux, btop, ...).
- **Safe by design** - pre-flight checks before anything is created (free VMIDs and IPs, VRRP ID
  collisions on the LAN, storage space, upstream reachability); a `--dry-run` mode; idempotent
  re-runs; the admin password never on a command line and stored root-only on the host, with a
  recovery tool if it is lost.
- **Clean layout** - bind mounts only, everything under one service directory
  (`/srv/technitium` by default): easy to back up, inspect and move.

## Simple by design

High availability here is built from standard parts. It doesn't depend on any feature of the
DNS server itself.

- **No application-specific DNS clustering** - this does **not** use Technitium's built-in
  clustering. Each node is a standalone Technitium server. Failover is plain VRRP (keepalived)
  on the Linux network stack, and replication is standard DNS zone transfer with NOTIFY, the same
  primary/secondary setup DNS has used for decades. There's no cluster state to keep healthy, no
  cluster-specific failure modes, and nothing extra to learn. During a rolling upgrade the two
  nodes can run different Technitium versions side by side, because zone transfer doesn't
  depend on the version. Everything Technitium-specific is in one file (`lib/technitium.sh`).
- **No split-DNS complexity** - clients use one address, the VIP, and get one consistent answer.
  You don't maintain separate internal and external views, and you don't keep an internal copy
  of your public zone. A local zone answers only the records you add to it and forwards every
  other name upstream, so `nas.example.com` resolves locally while `www.example.com` still
  reaches your public DNS.

## Requirements

- Proxmox VE 8 or newer (tested on 9.2), run as root on the host.
- One free IP per server (two for the default pair) plus one for the VIP, all on the same L2 network.
- Internet access from the host and the LXCs (Debian, Docker and Docker Hub).
- For each other host: root SSH from the first host (the script offers to install the key).

## Quick start

```bash
./deploy.sh                 # interactive; answers are saved for re-runs
./deploy.sh --dry-run       # questions + pre-flight checks, then print every action
./deploy.sh --config /root/proxmox-dns-ha-autodeploy/deploy.conf   # unattended re-run
```

Run without `--config` from a directory containing a `deploy.conf` (e.g. `cd /root/proxmox-dns-ha-autodeploy`)
and the script asks whether to use it for an unattended re-run.

See **[deploy.conf.example](deploy.conf.example)** for every setting (nodes, network, zones,
upstream, optional features, image tag) with comments. State lives in `/root/proxmox-dns-ha-autodeploy/`
on the host: `deploy.conf`, `credentials` (admin password, root-only) and logs.

## More secondaries

The first question asks how many secondary DNS servers to deploy: 1 (the default pair), 2 or 3.
Only with more than one are you asked the same few questions for each extra node: where it runs
(this host or another Proxmox host), VMID, hostname, IP and server name (`dns3`/`ns3`, ...).

- **Failover order** - every node is in the same VRRP group: ns1 (priority 150) holds the VIP,
  then ns2 (100), ns3 (90), ns4 (80). The VIP always sits on the healthy node with the highest
  priority and returns to ns1 60 s after it is healthy again.
- **Zones** - ns1 stays the only place to edit records; every secondary holds its own copy by zone
  transfer + NOTIFY (restricted to the secondaries' addresses), and the NS set lists every server.
- **Helpers** - `status.sh`, `zones.sh`, `backup.sh` and the drift report cover every node.
  `update.sh` and `reset-admin.sh` handle the nodes without the VIP first, lowest priority first,
  and the VIP holder last. Unattended upgrades are staggered 2 h apart per node.
- **Fewer later** - lower the number on a re-run and the nodes above it leave VRRP and zone
  transfers, then their LXCs are stopped and no longer start on boot. They are never destroyed:
  the script prints the `pct destroy` command for when you are sure.

## Day-2 helpers

Run on the Proxmox host; they reach every LXC directly over SSH, whichever host it runs on.

| Command | Purpose |
|---|---|
| `helpers/status.sh` | VIP holder, keepalived state, container health, zone sync (exit 1 on problems) |
| `helpers/update.sh [tag]` | Rolling Technitium upgrade (newest release by default), snapshot first, auto-rollback |
| `helpers/zones.sh list \| add ZONE... \| remove ZONE` | Manage additional local zones on every server |
| `helpers/lan.sh [status] \| set ROUTER_IP [DOMAIN] [--no-ptr] \| off` | Resolve DHCP client hostnames through your router (see below) |
| `helpers/backup.sh [create] \| list \| check \| restore SET NODE` | Back up every server, report configuration drift, restore one node (see below) |
| `helpers/failover-test.sh` | Repeat the live failover/failback test and report outage times |
| `helpers/reset-admin.sh [NODE\|all]` | Reset the web UI admin password, keeping users, zones and settings |

## LAN hostnames from your DHCP server

Many routers and DHCP servers (OpenWrt, OPNsense, pfSense, anything running dnsmasq) answer DNS
for their DHCP clients as `<hostname>.<local domain>`. Answer yes to the LAN question during
setup, or run `helpers/lan.sh set 192.168.1.1` later, and names under that domain go to the router.
Reverse lookups for the LXC subnet can go there too, so an IP shows its hostname.

- **Give the DHCP server its own subdomain** - e.g. `lan.example.com` when your zone is
  `example.com`. It can't use the zone itself, because each name is answered by one zone only.
  Set the router's *domain name* / *local domain* to that subdomain; the script prints the exact
  settings.
- **The router must register client names.** OpenWrt/dnsmasq do this by default. Some routers
  only publish their own name (a stock ASUS router tested here answers for `gw.<domain>` but not
  its clients);
  the checks show what the router actually answers.
- **Avoid a loop.** If the router's own upstream DNS is the VIP, it sends names it doesn't know
  back to these servers, and those lookups time out. Make the router answer its domain itself
  (dnsmasq: `local=/lan.example.com/`) or give it a different upstream. Deployment, `lan.sh`
  and `status.sh` all test for this.

## Backups and changes made by hand

`helpers/backup.sh` saves a full backup of each server through Technitium's own backup API:
settings, users, zones, allowed/blocked lists, apps, DHCP scopes and stats, including anything
you changed by hand. Sets go to `backups/<timestamp>/` in the state directory (root-only; they
contain the login database) with a copy of `deploy.conf`; the newest 14 are kept (`--keep N`).
For daily backups: `15 3 * * * /root/proxmox-dns-ha-autodeploy/helpers/backup.sh >/dev/null`.

The script doesn't try to merge changes. It sticks to a few simple ownership rules and reports
anything that breaks them:

| What | Who owns it |
|---|---|
| Records in the managed zones | You, **on ns1** (the secondaries receive them by zone transfer) |
| Zones | `deploy.sh` / `zones.sh` / `lan.sh` - a zone made in the web UI exists on that server only until you adopt it with `zones.sh add` |
| Forwarders, recursion, DNSSEC, serve-stale, blocklists, HTTPS UI, server name | `deploy.sh`: every run resets them to `deploy.conf`; change them through its questions |
| Everything else (cache, logging, apps, allowed/blocked lists, ...) | You - but make the same change on **every** server |

- `backup.sh check` (also run after each backup and summarised by `status.sh`) lists settings
  that differ between the servers, zones that exist on only one, and settings owned by
  `deploy.sh` that were changed since its last run, each with the fix. A Primary or Forwarder
  zone made on ns1 in the web UI is adopted with `zones.sh add <zone>`: it is kept as it is and
  each secondary gets a copy.
- A `deploy.sh` re-run lists the settings it owns that were changed by hand before it resets
  them, and asks first when run interactively.
- `backup.sh restore SET NODE` puts one node back exactly as it was in that set, onto the same
  node only (a backup carries its server's name and certificate). The node's current state is
  backed up first, and a backup from a newer Technitium version is refused (upgrade first with
  `update.sh`). Afterwards, the `deploy.sh`-owned settings and the zone copies are applied again,
  and the secondaries re-fetch every zone from ns1. Restoring ns1 alone is usually enough. If the restored
  login database has another admin password, run `reset-admin.sh` for that node.

## After deployment

1. Point your DHCP server's DNS option at the VIP (and, with LAN hostnames on, set its local
   domain to the LAN subdomain).
2. Manage records in the web UI on **ns1** (`https://<ns1-ip>:53443` by default, or
   `http://<ns1-ip>:5380` if you turned HTTPS off); login `admin`, password in
   `/root/proxmox-dns-ha-autodeploy/credentials`.

**Tip:** each LXC's **Notes** panel in the Proxmox UI has a quick reference for that server: its
role, its peer, the VIP, a web UI link, its zones and the helper commands. The notes are rewritten
on every deploy, so they stay current.

Design decisions and test results are documented in [PLAN.md](PLAN.md).

---
proxmox-dns-ha-autodeploy - by David Johnson ([@fiveangle](https://github.com/fiveangle))
