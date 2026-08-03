# AGENTS.md — flexisip-docker

## Project identity

Docker image build repository for two Belledonne Communications SIP components.
Not a source code repository. Delivers:

- **`ghcr.io/telecrypt-io/flexisip-proxy`** — SIP proxy (TLS port 5061)
- **`ghcr.io/telecrypt-io/flexisip-conference`** — Conference server (E2EE-capable)

Both images are built from upstream source and published to GHCR. Bonus `.deb`
packages are published to GitHub Releases (not consumed by Docker).

## ⚠️ The deployment server NEVER connects to this repository

**This is the designed flow, not a hardening tip. A deployed server has no
connection to this repo — none, at any point, in either direction.**

```
1. On the machine doing the deploying: read this AGENTS.md.
2. COPY docker-compose.yml and the config files onto the server.
3. Fill in credentials locally on the server, and start the stack.
```

That is the whole flow. There is **no clone, no remote, no fetch, no pull,
and no push** on a deployment host. If a deployed server has a `.git`
directory pointing at this repository, **that is an error to be corrected**,
not a supported configuration.

**Do not** "clone and remove the remote", "clone shallow", or "clone then
gitignore" — those all still produce a git working tree on a production host,
which is the thing this rule exists to prevent. Copy the files.

**Why this matters.** Config files are edited **in place on the server** and
hold real secrets — TURN credentials in `.env`, HA1 password hashes in
`config/users.conf`. Inside a clone, those live in a working tree attached to
a remote pointing at this **public** repository. On a live deployment they
were found **staged in the index** — one `git commit -a && git push` from
publication. An automated agent following a routine "commit your work"
convention would do exactly that, having no way to tell this repo from a
private one.

`.env` and `config/users.conf` are now untracked and gitignored, which
removes the largest hazard. **The no-connection rule still stands**, because
a working tree can still be pushed to and `git add -f` re-opens the hole.

**Updates are deliberate re-copies.** Without a clone there is no `git pull`.
Fetch the new file, diff it against what is running, and copy it across on
purpose. This is a feature, not a limitation: a `git pull` can silently
revert a local security fix (see "Config drift" below), and updates are far
rarer than credential edits.

**Why.** The deployment model has operators edit config files **in place** on
the server. In a clone, that working tree is attached to `.git` with a remote
pointing at this **public** repository. Real secrets — TURN credentials in
`.env`, HA1 password hashes in `config/users.conf` — then sit in a working
tree one `git commit -a && git push` from publication. On a live deployment
these were found **staged in the index**, which is one command from the same
outcome. An automated agent following a "commit your work" convention would
do exactly that, having no way to tell this repo from a private one.

`.env` and `config/users.conf` are now **untracked and gitignored** (they ship
as `.env.example` / `config/users.conf.example`), which removes the primary
hazard. **The copy-don't-clone rule still stands** as defence in depth: a
clone can still be pushed to, and `git add -f` or a future tracked file
re-opens the hole.

**What to copy** onto the server:

```
docker-compose.yml
versions.env
config/flexisip.conf
config/flexisip-conference.conf
config/domain-registrations.conf
.env.example              -> rename to .env,               then fill in + chmod 600
config/users.conf.example -> rename to config/users.conf,  then fill in + chmod 600
```

**Consequence — updates become manual.** Without a clone there is no
`git pull`; re-copy changed files deliberately and diff against your local
edits first. That is the intended trade-off: updates are rarer than
credential edits, and a deliberate diff is safer than a pull that could
revert a local security fix (see "Config drift" below).

**Never** commit real credentials to this repo. If it happens, treat the
credentials as compromised: rotate TURN credentials and every user password
(HA1 hashes are offline-crackable), then purge the history.

## Config drift — server-local edits are silently reverted by updates

Security and reliability fixes applied **only on a server** are lost the next
time the repo is updated. Observed on a live deployment: a fix binding SIP
UDP to loopback existed on the server for days but never upstream, so any
`git pull` would have silently re-exposed the unencrypted transport.

**Rule:** a change that is *security-relevant* or *generally correct* belongs
**upstream in this repo**, not in a local edit. Sanctioned local edits are
only: `<SIP_IP>` substitution, real credentials, and `.env` values. Anything
else is an upstream change. Before any update, diff the local config files
first.

## Findings from live-deployment review (2026-07)

Discovered while operating a real deployment. Recorded here so they are not
re-discovered the hard way. **Full detail in [`SECURITY.md`](SECURITY.md).**

- **Presence phones home to Belledonne.** Stock Linphone clients default to
  `sips:rls@sip.linphone.org` for presence, and an unrestricted
  `[module::Forward]` routes those subscriptions **out to the public
  Internet** — leaking account existence, online status, server IP and
  timing. Confirmed live via an established TLS connection to
  `sip11.linphone.org:5061`. **This contradicts the premise of a
  self-hosted deployment.** It is easy to dismiss as log noise. Detection
  commands and mitigations are in `SECURITY.md`; cutting it costs **zero**
  functionality because the subscriptions already fail with `404`.
- **E2EE does not cover metadata.** `log-level=message` retains
  who-called-whom records. Say "end-to-end encrypted media", not "we keep no
  records", unless you configured it that way.
- **`[module::DoSProtection]` disabled means fail2ban is REQUIRED**, not
  optional. Without it there is no rate limiting at any layer.
- **`[presence-server]` and `[module::Authorization]` blocks look like
  functional config but are warning suppressors.** Neither enables anything;
  deleting them removes no functionality and only restores log noise. Read
  the comment above a block before "cleaning it up."
- **`[module::MediaRelay]` does not weaken E2EE** — it forwards ZRTP
  ciphertext it cannot read. It is a CPU/bandwidth concern, not a
  confidentiality one.
- **Default datastore credentials ship weak on purpose** (MariaDB
  `flexisip`, Redis unauthenticated) and must be changed by an operator
  procedure — the no-runtime-substitution model means this repo cannot
  safely ship changed values. See `SECURITY.md`.
- **Beware `grep -c '503'` on proxy logs.** It massively overcounts —
  `503` appears inside connection IDs and dialled numbers. Grep
  `'503 Service Unavailable'`. On one deployment the naive count read 1533
  against 130 real occurrences.
- **`180 Ringing` → `408 Request Timeout` is ambiguous.** It is the
  signature of both an unanswered call and a push-notification failure. Logs
  cannot distinguish them; only a deliberate answered-call test can.

## Presence: this stack ships NONE — turn it off in clients

**This stack runs no presence server.** There is no `flexisip-presence`
service in `docker-compose.yml`, and the `[presence-server]` block in
`config/flexisip.conf` does **not** start one (it only suppresses a
deprecation warning — see the comment there).

**Consequence if you leave clients as-shipped:** they attempt presence
anyway, and **show meaningless status** — contacts stuck "offline" or
"unknown", because their `PUBLISH` has no server to reach and their
`SUBSCRIBE` goes to Belledonne's public RLS (which refuses it). The UI
implies a working feature that does not exist.

**Option A is this project's chosen default.** Option B is documented for
deployments that genuinely want presence.

### Option A — turn presence off in clients (CHOSEN DEFAULT)

Simplest way to stop clients displaying meaningless presence status.

> ⚠️ **CORRECTION (verified on a live deployment 2026-07-20): `publish=0`
> does NOT stop the phone-home leak.** An earlier version of this section
> claimed it did. That was wrong.
>
> `publish` and the RLS subscription are **independent mechanisms**:
>
> | Mechanism | Method | Controlled by | Destination |
> |---|---|---|---|
> | Presence publication | `PUBLISH` | `publish=0` in `[proxy_N]` | your own domain |
> | Resource/friends list | `SUBSCRIBE` | **RLS URI** (separate key) | `sips:rls@sip.linphone.org` |
>
> **Evidence:** on a live server the provisioning XMLs carried
> `publish=0` from 2026-07-17, and the proxy still egressed `SUBSCRIBE` to
> `sips:rls@sip.linphone.org` on 2026-07-18 and again on 2026-07-20.
> Turning off `publish` demonstrably left the leak running.
>
> **Consequence:** the **server-side out-of-domain routing restriction is
> the only reliable fix** — and it is the one this repo does not ship
> because its syntax is unverified (see `SECURITY.md`). Do not treat
> `publish=0` as leak remediation. The egress sweep is the only arbiter.

In the provisioning XML / `linphonerc`, in the **per-account** section
(`proxy_0`, `proxy_1`, … — one per account, **not** the global `[sip]`
section):

```ini
[proxy_0]
publish=0
```

`publish=0` is **verified**: it is what liblinphone itself writes into a
generated client config, in the `[proxy_N]` section. It is also liblinphone's
default, so the failure mode is a client that had presence explicitly
enabled, or a UI that offers a presence toggle.

Additionally, prevent the client from subscribing to Belledonne's resource
list. The relevant setting is the **RLS URI** in the global `[sip]` section
(clients ship a built-in default of `sips:rls@sip.linphone.org`; recent
Linphone Desktop exposes an explicit option to disable it).

⚠️ **The exact RLS key name is NOT verified.** It is absent from generated
client configs (built-in defaults are not written out), and liblinphone's
published provisioning-key reference is explicitly incomplete ("this page is
under construction"). **Do not guess** — an unrecognised key is **silently
ignored**, which looks like a fix while the client still leaks. Confirm
against the config reference for your client version, then **verify
empirically**:

```bash
# After re-provisioning ONE client, confirm nothing egresses:
docker logs --since 10m flexisip-proxy 2>&1 | grep 'Sending SIP request' \
  | grep -oE 'to sips?:[^ ]+@[^ ]+' | grep -v '<SIP_IP>' | sort | uniq -c
```
Expect **zero** external targets. That test is authoritative regardless of
which key name turned out to be correct.

### Research findings — presence: documentation vs. observed reality

Investigated 2026-07-20.

> 🚨 **FIELD EVIDENCE CONTRADICTS THE DESK RESEARCH BELOW. READ THIS FIRST.**
>
> An operator reported — with screenshots, on a latest-version mobile app —
> that **one user could see another user's online status**. Presence is
> therefore **demonstrably working** on a deployment that has:
> no presence server, `publish=0` set on every account, and (now) Belledonne's
> RLS blackholed.
>
> The conclusion below ("presence is vestigial, cannot be surfaced") is
> **wrong as a statement about observed behaviour.** The individual findings
> about SIP SIMPLE, the missing Desktop UI and the RLS URI still hold, but
> they clearly do **not** describe every path by which a Linphone client can
> obtain and display presence.
>
> **Most likely actual mechanism — peer-to-peer presence (RFC 3856), not a
> server:** client A sends `SUBSCRIBE` directly to B's AOR, the proxy routes
> it to B's registered contact like any other request, and B's client answers
> with `NOTIFY`. This needs **no presence server and no Belledonne** — only a
> proxy willing to route `SUBSCRIBE` between local users, which
> `[module::Forward]`/`[module::Router]` does by default. Note `publish=0`
> does not prevent it: `publish` governs *publishing to a presence server*,
> while a notifier answering a direct `SUBSCRIBE` is a separate path.
>
> **UNVERIFIED** — the mechanism above is inference, not observation. It must
> be confirmed by capturing `SUBSCRIBE`/`NOTIFY` between two local accounts
> with clients actually registered:
> ```bash
> docker logs --since 30m flexisip-proxy 2>&1 \
>   | grep -E 'SUBSCRIBE|NOTIFY' | grep -v linphone.org
> ```
> **If confirmed, disabling presence is a SERVER-side change** (stop routing
> the presence event package between users) — not a provisioning key, and not
> a presence server. Do not act on the desk research below until this is
> observed.

---

**Desk research (documentation-based — see the correction above before
relying on any of it):**

1. **Linphone 5.x+ dropped SIP SIMPLE presence entirely.** It no longer
   speaks the `PUBLISH`/`SUBSCRIBE` presence model that a
   `flexisip-presence` server implements; it uses RFC 4662 Resource Lists
   (RLS) instead. A presence server would therefore serve a protocol modern
   clients have stopped using.

2. **Linphone Desktop has had no UI to enable per-contact presence since
   v4.** The capability survives in the codebase but has no user-facing
   control (upstream issue linphone-desktop#84, closed as invalid). Users
   cannot turn presence display on even if a server provides it.

3. **Belledonne treat "self-hosted account pointed at our RLS" as a bug and
   have fixed it.** linphone-android MR !795 prevents the friends-list RLS
   URI being set for non-`sip.linphone.org` accounts, and MR !2516 removes
   it from the default RC with migration code stripping it from existing
   Core and FriendList state. **Upgrading clients may remove the phone-home
   at source**, with no provisioning change at all.

4. **The RLS URI is a client BUILT-IN default, not provisioning.** Verified
   on a live deployment: the provisioning XMLs contain no `rls`, `presence`
   or `subscribe` keys whatsoever, yet clients still subscribed to
   `sips:rls@sip.linphone.org`.

5. **The official provisioning-key reference does not document presence
   keys at all** — it states it is "under construction". So there is no
   authoritative key name to set, and guessing one is unsafe because an
   unrecognised key is silently ignored.

**Practical conclusion.** For a self-hosted deployment on modern clients,
presence is effectively **already off**: there is no server, no supported
protocol, and no client UI. What remains is the client's *attempt* to reach
Belledonne's RLS — a leak, not a feature — and that is handled at the
network layer by `config/hosts` (see SECURITY.md).

If contacts display as "offline" or with no status, that is the **expected**
result of having no presence data, not a misconfiguration to fix.

**Preferred remediation order:**
1. Keep the `config/hosts` blackhole (stops the leak regardless of client).
2. Upgrade clients — recent versions strip the RLS URI for non-Belledonne
   accounts by themselves.
3. Only then consider provisioning overrides, and verify empirically with
   the egress sweep, since no key name is authoritatively documented.

### Option B — actually run a presence server

If you want working presence, add Belledonne's `flexisip-presence` service to
the stack and point clients at it. That is a real feature addition — a new
service, its own config and datastore — **not** a config toggle, and this
repo does not currently ship it.

Either way, **leave the `[presence-server]` block in `config/flexisip.conf`
alone**: deleting it removes no functionality and only restores a startup
deprecation warning.

## Configuration model — configs are local and edited locally

`config/flexisip.conf`, `config/flexisip-conference.conf`, and `config/users.conf`
are **local files** mounted from the host. They are intended to be edited on the
deployment server — that is by design, not a workaround.

- The repo ships them **ready-to-use** with E2EE-capable defaults and a single
  `<SIP_IP>` placeholder; the deployer substitutes their public IP locally.
- **IP and domain management is deliberately local.** The entrypoints do **not**
  perform `<SIP_IP>` substitution at runtime (this was considered and rejected:
  configs are local files the operator owns). Do not "fix" this by adding in-container
  templating — it contradicts the supported deployment model.
- `.env` carries only environment-level values (`SIP_IP` for the ACME sidecar and
  containers, TURN credentials, `ENABLE_EKT_SERVER`). Everything else stays in the
  local config files.

## Workflow trigger rules

`.github/workflows/build.yml` only fires on changes to:

- `versions.env`
- `docker/**`
- `.github/workflows/build.yml`

**Config/docs changes (README, .env, docker-compose.yml, config/*.conf)
silently skip CI.** This is intentional — Dockerfiles are unchanged.

`.github/workflows/auto-bump.yml` runs nightly (03:00 UTC), detects new upstream
releases, and pushes `versions.env` updates to `main`.

## Version management

| File | Role |
|---|---|
| `versions.env` | Source of truth for which upstream version gets built |
| `state/built.json` | Source of truth for which versions have a published image |

Never edit `state/built.json` manually — it is updated by CI.

## Upstream source

GitLab (`gitlab.linphone.org`) is unreliable for submodule fetches. Both
Dockerfiles include retry+cleanup loops (nuking `.git/modules/*` between
retries). **If modifying Dockerfiles, preserve these loops.**

## Key commands

```bash
# Trigger a build (after changing versions.env)
gh workflow run build

# Check latest workflow runs
gh run list --limit 5

# Watch a running build
gh run watch <run-id>

# Pull images locally
docker pull ghcr.io/telecrypt-io/flexisip-proxy:latest
docker pull ghcr.io/telecrypt-io/flexisip-conference:latest
```

## No PRs

Push directly to `main`. No branch protection or PR gates configured.

## Permissions

The `build-debs` job needs `permissions: contents: write` override (top-level
permissions are `contents: read`). Do not remove this.

## ACME / TLS automation

- ACME sidecar (`goacme/lego:v5.2.2`) fetches Let's Encrypt IP certificates
  via HTTP-01 challenge.
- **Port 80/tcp must be reachable** from the Internet on `SIP_IP`.
- Let's Encrypt IP certs are short-lived (~6 days), renewed automatically.
- No DNS required — IP-address certificates only.
- No email required — Let's Encrypt account is created without email.
- Certificate + key are written to shared `flexisip_certs` Docker volume.
- Proxy auto-reloads certs every 60 seconds.

## Config placeholders

All config files use `<SIP_IP>` as a placeholder. Never hardcode IPs in
committed files. The user replaces `<SIP_IP>` with their server's public IP
during setup.

DB passwords are hardcoded to `flexisip` (internal only — MariaDB is not
exposed to the Internet). TURN credentials must be changed from defaults
(exposed to Internet on ports 3478/5349).

**TURN credential generation:** When helping a deployer fill in `TURN_USER`
and `TURN_PASSWORD`, always generate them via shell commands (e.g.
`openssl rand -hex 12`) rather than outputting strings directly. LLMs
mis-handle credential strings — output may contain invisible characters,
formatting artifacts, or be difficult to copy correctly. Shell commands
produce verified, copy-paste-safe values.

## E2EE

- **Enabled by default** in `config/flexisip-conference.conf` (`[conference-server]`
  `audio-engine-mode=sfu`, `video-engine-mode=sfu`, `encryption=zrtp`). No runtime
  rewriting — the config ships ready.
- `ENABLE_EKT_SERVER=true` in `.env` is retained only as an **intent signal**; it no
  longer triggers any entrypoint config change.
- EKT plugin is always installed but only active in SFU mode.
- **Verify:** conference log line
  `EKT server plugin for core sip:conference-focus@… has been succesfully loaded`
  and `E2EE mode ACTIVE`.
- **To disable E2EE:** comment out the three `audio-engine-mode`/`video-engine-mode`/
  `encryption` lines in `config/flexisip-conference.conf`. (Media then unencrypted;
  flexisip raises no error.)
- **EKT module license:** Provided by Belledonne Communications. For proprietary
  license holders, a separate license may be required. For AGPLv3 self-hosting
  (this project's purpose), it is freely usable. See `NOTICE`.
- **No liability:** Author(s) bear no responsibility for misuse. See `NOTICE`.

## Configuring E2EE — in a flash (for LLMs and operators)
E2EE group conferences work out of the box. Nothing is rewritten at runtime.
1. `config/flexisip-conference.conf` already contains, under `[conference-server]`:
     audio-engine-mode=sfu
     video-engine-mode=sfu
     encryption=zrtp
   Leave them as-is (uncomment only if ever absent).
2. `.env` keeps `ENABLE_EKT_SERVER=true` as an intent signal (no rewriting).
3. Deploy: `docker compose up -d`.
4. Verify: `docker logs flexisip-conference 2>&1 | grep -E "EKT server plugin|E2EE mode ACTIVE"`
   Expect both lines. If missing, E2EE is NOT active (media unencrypted).
To DISABLE E2EE: comment the three lines in step 1.

## Key files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Deployment layout (proxy, conference, acme, mariadb, redis, coturn) |
| `config/flexisip.conf` | Proxy config template |
| `config/flexisip-conference.conf` | Conference config template |
| `.env` | Environment variables template |
| `docker/proxy/Dockerfile` | Proxy image build |
| `docker/conference/Dockerfile` | Conference image build |
| `docker/proxy/entrypoint.sh` | Proxy entrypoint (EKT_SERVER toggle) |
| `.github/workflows/build.yml` | CI build pipeline |
| `.github/workflows/auto-bump.yml` | Nightly upstream version detection |
| `versions.env` | Pinned upstream versions |
| `state/built.json` | Published image versions (CI-managed) |
| `SECURITY.md` | E2EE verification and threat model |
| `NOTICE` | Attribution and license details |

## Testing

Smoke test (`build.yml` job 4) checks:
- OCI labels present on both images
- `entrypoint.sh` exists in both images
- `*ektserver*.so` exists in conference image at
  `/opt/belledonne-communications/flexisip-conference/lib/liblinphone/plugins/`

No unit tests. Verification is manual against a running deployment.

## Known issues

- **auth-domains-mode=legacy warning:** Previously emitted by both proxy and
  conference at startup (from upstream Flexisip v2.6 defaults). Now suppressed
  in both config/flexisip.conf and config/flexisip-conference.conf via a
  [module::Authorization] section with auth-domains-mode=static.

- **users.conf has NO comments:** Flexisip's authdb parser rejects # comments
  anywhere in the file. config/users.conf contains only version:1 + credential
  lines. The format is documented in README.md (Quick start) instead.

- **`tcp:` transport prefix crashes the proxy:** flexisip 2.6 only accepts
  `sip:` (UDP) and `sips:` (TLS) in `transports`. A `tcp:` prefix →
  "could not enable transport … Invalid argument" crash-loop. The proxy uses
  both `sip:` (5060, the proxy→conference UDP hop) and `sips:` (5061, client TLS).

- **Conference server runs on host networking** (`network_mode: host`): it binds
  127.0.0.1:6064 and the proxy reaches it via loopback. Because Docker service
  names don't resolve under host networking, the conference config points
  MariaDB/Redis at 127.0.0.1 (published on loopback in docker-compose.yml).

- **MediaRelay enabled (`enabled=true`):** engages automatically on NAT legs.
  flexisip 2.6 does NOT accept `force-relay` / `relay-ips` in that section.

- **Conference routing is automatic:** no `conference-factory-uri` proxy directive
  (invalid in v2.6) — the conference server registers its factory URI with the
  proxy's registrar.

- **Reference client is Linphone** (baresip can't do group E2EE / LIME+EKT).
  Multi-client testing on one host collides on RTP port 7078 — isolate clients
  in separate network namespaces. Headless testing needs a pulseaudio null sink.
  mbedTLS Linphone clients may reject the 2025 Let's Encrypt chain; never ship
  `verify_server_certs=0` in production.

- **E2EE is on by default** — `config/flexisip-conference.conf` ships
  `audio-engine-mode=sfu` + `video-engine-mode=sfu` + `encryption=zrtp`;
  `ENABLE_EKT_SERVER=true` in `.env` is an intent signal only. With E2EE off
  (the three lines commented), conferences still work but media is NOT
  ZRTP-encrypted and flexisip raises no error (silently absent E2EE). Verify via
  the conference log line
  `EKT server plugin for core sip:conference-focus@… has been succesfully loaded`.

- **`482 Loop Detected` on client REGISTER — root cause `reg-on-response`:**
  `config/flexisip.conf` sets `reg-on-response=false` (this proxy is the terminal
  registrar). With `true`, the Registrar forwards each REGISTER to the domain's
  next hop; in a single-proxy deployment that next hop is the proxy itself →
  self-forward → `482 Loop Detected` on every client REGISTER. The conference
  server registers over `127.0.0.1` and slipped past the loop check, masking the
  bug. **Keep `reg-on-response=false` unless a proxy is chained in front.**
- **`482 Loop Detected` on INVITE / forward-loop (upstream #187):** an INVITE from
  a NATed client whose visible source IP equals the proxy's own public IP can be
  misclassified as a routing loop. Mitigate with client STUN/TURN (coturn,
  included) so clients advertise a public/relay Contact, and keep
  `aliases=<SIP_IP>` in `[global]`. Test with genuinely remote clients — same-host
  netns masquerade presenting the server's own IP is a false-positive.

- **Re-register after proxy restart:** Redis-persisted bindings go stale on
  `docker restart flexisip-proxy` → `404`/`482` until clients re-register.
  Restart clients or shorten `default-expires` during rollout.

- **Healthchecks added (Issue 7):** compose now health-checks mariadb, redis,
  coturn (UDP 3478), proxy (TCP 5061), conference (UDP 6064). Monitor proxy
  `503`s, cert expiry, conference failures, RTP-relay.

- **DoSProtection disabled:** The `[module::DoSProtection]` section in
  `config/flexisip.conf` sets `enabled=false` because the module
  requires iptables, which is not available (or desirable) inside Docker
  containers. For production DoS protection, use external mechanisms (cloud
  firewalls, fail2ban, etc.).

## Handover docs

`handover/` directory contains additional context:
- `QUICK-HANDOVER.md` — project overview and critical runtime config
- `SESSION-NOTES.md` — session context
- `SOURCE-EXCERPTS.md` — upstream source excerpts
- `meta-repo-template/` — template for meta-repository structure
