# Session Notes — Flexisip TLS cert reload + 2.6.1 build pipeline

Date: 2026-08-10

Comprehensive record of the investigation and fixes for the `onesapta-sip`
deployment. Nothing should be lost between sessions.

## 1. The original problem

The Flexisip server at `onesapta-sip` (139.100.227.125) was serving an
**expired TLS certificate** on `sips:5061`. The on-disk cert was renewed by
the ACME sidecar, but never reached the wire, so clients got an expired cert.

Symptom (from a remote client):
```
openssl s_client -connect 139.100.227.125:5061
  notAfter=Jul 30 ... (EXPIRED 10 days)
```
while on-disk cert was fresh (Aug 6 → Aug 13).

## 2. Root cause — cert live-reload broken

`transports=sips:0.0.0.0:5061 sip:127.0.0.1:5060` in `config/flexisip.conf`.

- At startup, sofia-sip expands `0.0.0.0:5061` into the concrete bound
  addresses (139.100.227.125, 127.0.0.1, 172.17.0.1, 172.18.0.1).
- On reload, flexisip passes the raw `0.0.0.0:5061` back to
  `nta_agent_update_tport_certificates`.
- sofia-sip can't find a transport bound to `0.0.0.0` (they're all concrete IPs)
  → logs `tport_update_certificate: no transport found for 0.0.0.0:5061`.
- flexisip's `agent.cc::updateTransport` advances `lastModificationTime`
  unconditionally, so the failed reload isn't retried until the next cert mtime
  change (next ACME renewal).

**This reproduces on BOTH 2.6.0 AND 2.6.1.** The upstream `7270a857` "multi
transports" fix did NOT resolve it (verified live on 2.6.1).

## 3. The fix (VERIFIED WORKING 2026-08-10)

**Bind sips to the concrete public IP instead of `0.0.0.0`.**

Three coordinated changes (all use `<SIP_IP>` / `${SIP_IP}`, no hardcoded IPs):

1. `config/flexisip.conf`:
   `transports=sips:<SIP_IP>:5061 sip:127.0.0.1:5060`
2. `config/flexisip-conference.conf`:
   `outbound-proxy=sips:<SIP_IP>:5061;transport=tls`
   (loopback TLS is no longer bound, so conference reaches proxy via public IP)
3. `docker-compose.yml` proxy healthcheck:
   probes `${SIP_IP}:5061` (was `127.0.0.1:5061`) + `openssl x509 -checkend 0`

**Verification** (the decisive log difference):
- Before (0.0.0.0): `Updating TLS certificate for transport: sips:0.0.0.0:5061`
  followed by `Error while updating the TLS transport: ... no transport found`.
- After (concrete IP): `Updating TLS certificate for transport: sips:139.100.227.125:5061`
  with **no** error line. 0 errors. Reload succeeds.

Diagnostic procedure (to confirm a reload):
```
# set tls-certificates-check-interval=1 (1 MINUTE, not seconds)
sed -i 's/^tls-certificates-check-interval=.*$/tls-certificates-check-interval=1/' config/flexisip.conf
docker restart flexisip-proxy
VOL=$(docker volume inspect flexisip-docker_flexisip_certs --format '{{.Mountpoint}}')
touch $VOL/cert.pem $VOL/privkey.pem   # bump mtime to trigger reload
sleep 75
docker logs --since 2m flexisip-proxy | grep -iE 'updateTransport|tport_update'
# revert check-interval to 60 and restart
```
Expect `Updating TLS certificate for transport: sips:<SIP_IP>:5061` with NO
`Error while updating` line.

## 4. `tls-certificates-check-interval` unit trap

The parameter's default unit is **MINUTE** (`DurationMIN`), so `=60` means
**60 minutes**, not 60 seconds. The old config comment saying "every 60 seconds"
was wrong. Hourly cadence is fine (ACME renews every 12h). To set 60 seconds use
`=60s` with the `s` suffix.

## 5. Build pipeline — gitlab WAF workaround + pre-clone

gitlab.linphone.org is behind a WAF that blocks plain `git`/`curl` for some
repos. `xsd` (a submodule added in flexisip 2.6.1 by upstream `fe9aed81`,
"fix(xml): prevent XXE attacks") is unreachable from plain HTTP clients.

Solution lives entirely in CI (the "surrounding environment"), NOT in the
Dockerfiles:

- `scripts/gitlab-proxy.js` — Node HTTP proxy routing `gitlab.linphone.org`
  requests through headless Chrome (Playwright CDP) to pass the WAF.
  Path-rewriting proxy (NOT HTTP CONNECT). Git points at it via:
  `git config --global url.http://127.0.0.1:8843/.insteadOf https://gitlab.linphone.org/`
- `build.yml` — each gitlab-touching job (build-debs, build-proxy-image,
  build-conference-image):
  1. `cd scripts && npm install`
  2. start proxy: `nohup env CHROME_BIN=... node gitlab-proxy.js &` (background)
  3. wait for proxy: `curl http://127.0.0.1:8843/explore/projects`
  4. `git config --global url.http://127.0.0.1:8843/.insteadOf https://gitlab.linphone.org/`
  5. pre-clone upstream + submodules on the runner (through the proxy)
  6. stop proxy (in an `if: always()` step)
- Docker builds use `network: host` and the Dockerfiles `COPY src-proxy/ /src/`
  (proxy) / `COPY src-conf/ /src/` (conference). Dockerfiles no longer git-clone.
- `.dockerignore` whitelists `docker/**`, `src-proxy/**`, `src-conf/**` to keep
  the build context small.

**Pre-clone submodule recipe (critical):**
- Shallow submodule clones (`--depth 1`) lose tags → cmake `git describe`
  (`bc_compute_full_version`) fails.
- Full submodule clones 502 through the proxy (CDP page.evaluate buffer limit on
  large packfiles).
- **Working recipe:**
  ```
  git clone --depth 1 --branch $VER https://gitlab.linphone.org/BC/public/flexisip.git src-proxy
  cd src-proxy
  git submodule update --init --recursive --filter=blob:none   # full history+tags, small packfile
  git submodule foreach --recursive 'git reset --hard HEAD'     # materialize all blobs
  ```
  `--filter=blob:none` keeps the packfile small (full history + tags, blobs
  deferred); `git reset --hard HEAD` lazily fetches + materializes all blobs so
  the working tree is complete for `COPY`.

The GitHub Actions `ubuntu-24.04` runner has Chrome + Node pre-installed; the
workflow installs `playwright-core`.

## 6. Auto-bump trigger gap (FIXED)

`auto-bump.yml` committed `versions.env` with `GITHUB_TOKEN`. GitHub Actions
does NOT start new workflows from `GITHUB_TOKEN` commits (anti-loop), so the
version bump never triggered `build.yml`. Observed: bump to 2.6.1 on 2026-07-31
produced no build for 9 days.

Fix: `auto-bump.yml` now runs `gh workflow run build.yml --ref main` after the
commit (needs `permissions: actions: write`). `workflow_dispatch` is not subject
to the GITHUB_TOKEN anti-loop restriction.

## 7. Strict version fixation

Deployments must pin explicit image tags, NEVER `:latest`. `docker-compose.yml`
now references `ghcr.io/potemkinco/flexisip-proxy:2.6.1` and
`flexisip-conference:1.0.1`. `:latest` is only a CI convenience alias and must
not be used on production hosts.

## 8. Deployment status (as of 2026-08-10)

- Images: `flexisip-proxy:2.6.1`, `flexisip-conference:1.0.1` on GHCR.
- `state/built.json` → `{"flexisip": "2.6.1", "flexisip-conference": "1.0.1"}`.
- Deployed to `onesapta-sip` (139.100.227.125), all 6 containers healthy.
- Proxy sips bound to `139.100.227.125:5061` only (loopback TLS gone).
- Conference outbound via `sips:139.100.227.125:5061`, focus registered/bound.
- Cert on wire: valid Aug 9 → Aug 16. Live-reload now works, so ACME renewals
  propagate automatically.
- Healthcheck now validates cert validity on `${SIP_IP}:5061` (not just TCP).

## 9. Server access

- Host alias: `onesapta-sip` (root, port 30916, key ~/.ssh/selectel)
- Deploy path: `/opt/flexisip-docker/`
- Configs are local files mounted into containers (edit in place, no git on server)
- SIP_IP in server `.env` = `139.100.227.125`

## 10. Related commit history (flexisip-docker, main)

- `77a34f3` fix: bind sips to concrete IP so TLS cert live-reload works
- `cdb1954` docs: correct TLS reload fix (bind sips to concrete IP, not 2.6.1)
- `685eebc` ci: use --filter=blob:none + reset for submodules
- `791f0d9` ci: pin images to explicit version tags (never :latest)
- `26146b9` ci: pre-clone upstream through Chrome proxy; fix auto-bump build trigger

## 11. 2026-09-10 migration, version audit, and runtime hardening

- The GitHub repository transfer has already completed: the canonical repository
  is now `PotemkinCo/flexisip-docker`. The old TeleCrypt-io URL redirects there.
  Update local `origin` to `https://github.com/PotemkinCo/flexisip-docker.git`
  before future pushes.
- There is no `2.6.2` image/tag in the custom GHCR namespace. The old
  `ghcr.io/telecrypt-io/flexisip-proxy:latest` resolved to the same digest as
  `2.6.1`, while `:2.6.2` was manifest-unknown. The upstream changelog has a
  `2.6.2 Hotfix` heading, but no upstream `2.6.2` release tag; the listed fixes
  are unrelated to the push-timeout crash.
- The 2.6.0/2.6.1 mismatch came from two separate drifts: the 2026-07-31
  nightly bump committed `versions.env=2.6.1`, but a `GITHUB_TOKEN` commit did
  not trigger the push build; then the old decision condition treated
  `current=2.6.1, built=2.6.0` as no change. A successful build/state update
  landed on 2026-08-10. The server's `versions.env` was then left stale even
  though the running proxy was already 2.6.1.
- `auto-bump.yml` now selects the highest numeric stable tag, retries GitLab,
  falls back to official GitHub mirrors, and explicitly retries a build whenever
  `versions.env` and `state/built.json` differ. `build.yml` now uses the
  `PotemkinCo` GHCR namespace and smoke-tests the actual Flexisip binary version.
- Intended push settings are explicit in `config/flexisip.conf`: immediate
  initial push (`timeout=0`), three retries (`retransmission-count=3`), and a
  7-second retry interval (`retransmission-interval=7`). `fork-late=true` is
  retained. Presence remains enabled as before; no presence-related change was
  made.
- Core dumps are bounded by Docker's proxy `RLIMIT_CORE` at 256 MiB. Flexisip's
  own `dump-corefiles=false` remains explicit because enabling that application
  switch raises the limit to unlimited. The proxy entrypoint changes into the
  persistent `/var/opt/belledonne-communications/cores` directory before
  starting Flexisip, so future dumps are retained in the Docker volume.
- Before replacing the proxy container, preserve the existing `/core` dump in
  `/opt/flexisip-docker/core-dumps/`; it was approximately 39.5 MiB and is the
  valuable crash artifact from the prior incident.
- After deployment, verify: image tags/digests under `ghcr.io/potemkinco`,
  process version `2.6.1`, proxy `Max core file size` = 262144 KB, the three
  push settings above, all six containers healthy, and disk usage.

## 12. 2026-09-11 boot outage and maintenance window

- The host performed a clean systemd reboot at 04:03:12-04:03:17 CEST; the
  preceding boot ended normally, with no evidence of a kernel crash or power
  failure in the available journal.
- During the new boot, systemd reported an ordering cycle involving
  `/etc/systemd/system/caddy-cert-reload.path`: its `After=docker.service`
  dependency led through `containerd.service` and `basic.target` back to
  `paths.target`. To break the cycle, systemd deleted the `docker.service/start`
  job. `docker.socket` and `containerd` were running, but `dockerd` and all six
  application containers were not.
- At 10:21 CEST the first Docker health query opened the still-listening Docker
  socket. Socket activation started Docker and its restart policies restored
  all six containers; they were healthy by 10:22. This was not a package update
  or a Docker crash at 10:21. The Docker packages had been updated the previous
  day; the 2026-09-11 unattended-upgrade run found nothing to install.
- The boot-order fix is to remove the unnecessary `After=docker.service` from
  `caddy-cert-reload.path`; apply and validate it only during the maintenance
  window. Until then, treat server-side configuration, service, package, and
  deployment changes as permitted only from 02:00 to 04:00 Europe/Berlin.
- CI run `34580807472` (the retry of commit `9965f63`) completed successfully:
  build, push, smoke test, and state publication all passed. The resulting
  amd64 manifest digests are proxy `sha256:857f04806d47ec4194ec439a093f825519cb3598206ac942dd8e76efb8354819`
  and conference `sha256:62b1081084f1554915911f15ec72f3eff54d24f48566494ad88218482356f55b`.
- The live server was deliberately not changed during working hours after this
  rule was agreed. Until the maintenance window, it still runs the prior
  TeleCrypt-namespaced compose configuration and has stale `versions.env`
  metadata even though its running binaries were already 2.6.1/1.0.1.
- Automatic APT maintenance is a separate scheduling issue: `apt-daily.timer`
  is configured for 06:00 and 18:00 with up to 12 hours of random delay, while
  `apt-daily-upgrade.timer` is configured for 06:00 with up to 60 minutes of
  random delay. Neither caused the 2026-09-11 Docker outage, but these timers
  should be constrained to the 02:00-04:00 Europe/Berlin window if that policy
  applies to unattended package updates as well; `Persistent=true` should also
  be reviewed so a missed run is not replayed during working hours.

The normal maintenance-window rule above was explicitly superseded for this
setup by the user on 2026-09-11; the production changes and reboot validation
were therefore performed during working hours.

## 13. 2026-09-11 production setup completed

- Rollback snapshot created before changing the server:
  `/opt/flexisip-docker/backups/20260911T113659Z`. It contains the compose
  files, versions/configuration, service definitions, container inspections,
  and the prior proxy core dump under `cores/proxy-core-pre-change`.
- Removed the unnecessary `After=docker.service` from
  `/etc/systemd/system/caddy-cert-reload.path`; `systemd-analyze verify`
  passed and the path is now active without a Docker dependency. This removes
  the boot ordering cycle that deleted Docker's start job.
- APT timers now run at 02:00 (`apt-daily`) and 03:00
  (`apt-daily-upgrade`) Europe/Berlin, with zero random delay and
  `Persistent=false`. Both are enabled and scheduled accordingly.
- Production now uses `ghcr.io/potemkinco/flexisip-proxy:2.6.1` and
  `ghcr.io/potemkinco/flexisip-conference:1.0.1`; the pulled registry digests
  were proxy `sha256:b6d150a344ca3048939fedc0430b9a5c954a98b044a78e4def0e689ea35186bb`
  and conference `sha256:8163c91c7d960d5ab23e16e0ff530b109b8e546abd80c15f02737987e35255bb`.
  `versions.env` is now 2.6.1/1.0.1.
- Effective Flexisip settings are `timeout=0`, `retransmission-count=3`,
  `retransmission-interval=7`, and `fork-late=true`. The proxy process is
  Flexisip 2.6.1. Core dumps are bounded at 256 MiB (`RLIMIT_CORE` soft and
  hard), and the persistent core directory is
  `/var/opt/belledonne-communications/cores`.
- A controlled reboot completed successfully. After boot, Docker, containerd,
  Caddy, and `caddy-cert-reload.path` were active; all six containers were
  healthy; SIP listeners were present on TCP 5061/5060; and the boot journal
  contained no ordering-cycle or deleted-Docker-start-job message. Proxy
  restart count is 0; conference restart count 5 is inherited from the earlier
  boot restoration history, not from this deployment.
- Post-reboot disk state: 13 GiB used of 25 GiB (55%), 11 GiB available.
  Docker reports 2.586 GiB reclaimable in unused images, mostly the old image
  set; do not remove it without confirming rollback policy. The existing
  `docker-image-prune.timer` is enabled weekly on Sunday around 03:30 with a
  30-minute random delay and prunes dangling images older than seven days.
  Journald is using 59 MiB and has `MaxRetentionSec=1day`.
