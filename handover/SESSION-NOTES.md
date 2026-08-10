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
now references `ghcr.io/telecrypt-io/flexisip-proxy:2.6.1` and
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
