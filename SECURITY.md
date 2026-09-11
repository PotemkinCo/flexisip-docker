# Security and E2EE

This document explains what end-to-end encryption (E2EE) means in a Flexisip
deployment, how the EKT plugin provides it, and how to verify the deployment
is actually using it.

## What is and isn't E2EE

A conference is **end-to-end encrypted** when the audio/video media streams
are encrypted by the sender client and decrypted only by the recipient
clients. The conference server must be able to forward the encrypted packets
without being able to decrypt them.

This is **not** the same as TLS or SRTP. Those protect media between the
client and the server, but the server decrypts and re-encrypts on the other
side. With E2EE, the server has no way to read the media.

| State | Server can read media? | Encryption hops |
|---|---|---|
| **Unencrypted** (no SRTP) | Yes | None |
| **SRTP to server** (default Flexisip `mixer` mode) | Yes | Client → Server |
| **ZRTP / SRTP-DTLS to server** | Yes (in mixer mode) | Client → Server |
| **E2EE conference (SFU + EKT)** | **No** | Client → Client |

In Flexisip's default audio mode (`mixer`), the server decodes every stream,
mixes them, and re-encodes the mixed result. The server necessarily sees the
raw media, so the conference cannot be end-to-end encrypted regardless of
any transport encryption.

To get true E2EE, the conference must run in **SFU mode**: the server only
forwards RTP packets and rewrites a few RTP header fields, never decoding
or re-encoding. SFU mode is configured by:

```ini
[conference-server]
audio-engine-mode=sfu
video-engine-mode=sfu
encryption=zrtp
```

The `flexisip-conference` image's entrypoint does not rewrite configuration.
The mounted `config/flexisip-conference.conf` is authoritative, and the EKT
plugin is verified at image-build time and reported at startup.

## The EKT plugin

The EKT plugin (`linphone_ektserver.so`, included in the conference image)
implements **RFC 8870 Encrypted Key Transport** combined with **RFC 8723
double-SRTP**. It runs inside the conference server and dispatches the
per-conference encryption key to all participants via SIP
PUBLISH / SUBSCRIBE / NOTIFY. Each client then uses the EKT key to derive
the inner SRTP key that protects media between clients.

Without the EKT plugin, `flexisip-conference` cannot establish E2EE
conferences. The plugin is always installed in the conference image but only
takes effect when SFU mode is configured.

## Verifying E2EE in a running deployment

1. **Plugin present:**
   ```bash
   docker exec flexisip-conference ls -l \
     /opt/belledonne-communications/flexisip-conference/lib/liblinphone/plugins/linphone_ektserver.so
   ```

2. **Plugin loaded at startup:**
   ```bash
   docker logs flexisip-conference 2>&1 | grep -i "EKT server plugin"
   ```
   Expected: `EKT server plugin for core ... has been successfully loaded`

3. **Conference in SFU mode:**
   ```bash
   docker exec flexisip-conference \
     grep -E "audio-engine-mode|video-engine-mode|encryption" \
     /etc/opt/belledonne-communications/flexisip-conference/flexisip-conference.conf
   ```
   Expected: `audio-engine-mode=sfu`, `video-engine-mode=sfu`, `encryption=zrtp`

4. **Client-side indicator:** A Linphone client in an E2EE conference shows
   a padlock with the label "End-to-end encrypted" (or similar, depending on
   client version and platform). See the table below.

5. **Programmatic check:** `liblinphone` exposes
   `linphone_conference_get_security_level()`. A correct E2EE conference
   returns `LinphoneConferenceSecurityLevelEndToEnd`. The other values are
   `None` (unencrypted) and `PointToPoint` (only encrypted to the server).

   A test program can be built against `liblinphone` headers and run
   against the live conference to confirm this.

## Client UI indicators (verified from upstream wiki and changelogs)

| State | Linphone indicator (desktop & mobile) |
|---|---|
| Unencrypted | Red padlock with slash |
| SRTP (transport only, server terminates media) | Green padlock |
| **E2EE conference (LIME + EKT active)** | **Padlock + "End-to-end encrypted" label** |
| Misleading legacy label (pre-6.1.1) | "End-to-end encrypted call" may appear when only the leg to the server is E2EE; fixed in linphone-desktop 6.1.1+ |

The desktop changelog (6.1.1) explicitly notes the fix:

> Fixed "End-to-end encrypted call" label while in conference, the call may
> be end-to-end encrypted but only to the conference server, not to all
> participants.

When verifying, ensure all clients joining the conference show the
"End-to-end encrypted" indicator. If only some clients do, the E2EE
negotiation has not completed for all participants.

## Threat model notes

- The conference server **authenticates participants** but does not need
  to know the EKT key. The key is distributed over SIP signaling, but the
  SIP signaling itself is end-to-end authenticated via the EKT key exchange.
- **Active MITM:** prevented by the EKT key agreement (RFC 8870 § 5.2).
  An attacker who can rewrite SIP signaling cannot derive the EKT key.
- **Compromised server:** cannot read media. The EKT key is per-conference
  and is only revealed to the participants, not the server.
- **Compromised client:** can read its own media and impersonate that
  client, but cannot decrypt other participants' media.
- **Replay / reordering:** handled by SRTP sequence numbers inside the
  EKT-protected inner SRTP.

## What E2EE does NOT protect: metadata

**E2EE here protects call *content*. It does not protect *metadata* — who
called whom, when, for how long, from which IP.** For many threat models
(journalists, activists, anyone facing traffic analysis) the social graph
plus timestamps is more revealing than the audio. Do not let "E2EE" be read
as "the server knows nothing."

The media property above remains true and is verifiable: the server forwards
ciphertext it holds no key for. It is simply **narrower than "private."**

Two concrete metadata exposures ship with this stack by default:

### 1. Signaling logs at rest

Both configs default to `log-level=message`, which records REGISTER/INVITE
traffic — accounts, call pairs, timing, contact IPs — retained by the host's
systemd journal. Production journald is capped at 200 MiB with one-day
retention; a disk image, host compromise, or lawful request still yields call
records within that window.

**Decide and document a retention posture.** For production, consider
`log-level=warning`. Note the trade-off honestly: several diagnostics in the
troubleshooting docs grep for `401`/`503` patterns that `message` provides.
Lowering the level is a real trade-off, not a free win.

### 2. Presence phones home to Belledonne

**Stock Linphone clients default to Belledonne's PUBLIC resource-list server
for presence** (`sips:rls@sip.linphone.org`). With an unrestricted
`[module::Forward]`, a self-hosted proxy will **route those subscriptions
out to the public Internet**, disclosing to a third party: that a given
account exists on your server, that it is online, your server's public IP,
and presence timing.

This was observed on a live self-hosted deployment (2026-07-20): an
established TLS connection from the proxy to `sip11.linphone.org:5061`,
carrying `SUBSCRIBE` to `sips:rls@sip.linphone.org`. The requests are
refused with `404` — **but the metadata is in the request, so the refusal
does not undo the disclosure.**

**It is easy to miss**, because presence errors look like ordinary log noise
and get dismissed as a client quirk.

**Detect (any non-local peer or target is a leak):**
```bash
# Every out-of-domain target the proxy actually SENDS (not merely receives):
docker logs flexisip-proxy 2>&1 | grep 'Sending SIP request' \
  | grep -oE 'to sips?:[^ ]+@[^ ]+' | grep -v '<SIP_IP>' | sort | uniq -c

# Live outbound SIP connections:
ss -tn state established | grep 5061
getent hosts <peer-ip>        # confirm whose infrastructure it is
```

**Cutting it costs nothing.** These subscriptions already fail with `404`,
so no working feature depends on them. Removing the disclosure has no impact
on calls, registration, conferencing, or E2EE.

**Mitigations, in order of durability:**

1. **Server-side out-of-domain routing restriction — the durable control.**
   It holds regardless of client configuration, so a reinstalled or
   re-provisioned client cannot reintroduce the leak.

   Flexisip modules accept a generic `filter=` expression, and
   `request.uri.domain == '...'` is valid filter syntax, so restricting
   `[module::Forward]` to the local domain is the natural lever.

   ⚠️ **NOT SHIPPED IN THIS REPO, AND DELIBERATELY SO.** The exact
   expression is **unverified on this stack**, and the behaviour of
   *non-matching* requests (clean rejection vs. silent timeout) has not been
   established. Flexisip rejects unknown parameters **at startup**, so a
   wrong value means the proxy does not boot and all SIP service stops.
   Validate in a throwaway container against the configuration reference for
   your exact Flexisip version before using it.

   ⚠️ **This is the only reliable fix.** See the correction below: the
   obvious client-side lever (`publish=0`) does **not** stop this leak.

2. **Client-side provisioning override** — set the RLS/presence URI
   explicitly so clients never point at Belledonne. Confirm the exact key
   against the Linphone SDK config reference for your client version: an
   **unrecognised key is silently ignored**, which looks like a fix while
   still leaking. Verify with the detection commands above.

3. **Stopgap** — blackhole the hostname (`/etc/hosts`) or drop the egress in
   the firewall. Instant and reversible; stops traffic *leaving* but not
   clients generating it.

### ⚠️ `publish=0` does NOT fix this leak — verified

Disabling presence publication is the obvious first guess. **It does not
work**, because `PUBLISH` and the RLS `SUBSCRIBE` are independent:

| Mechanism | Method | Controlled by | Goes to |
|---|---|---|---|
| Presence publication | `PUBLISH` | `publish=0` in `[proxy_N]` | your own domain |
| Resource/friends list | `SUBSCRIBE` | **RLS URI** (a different key) | `sips:rls@sip.linphone.org` |

**Evidence from a live deployment:** provisioning XMLs carried `publish=0`
from 2026-07-17; the proxy still egressed `SUBSCRIBE` to
`sips:rls@sip.linphone.org` on 2026-07-18 and 2026-07-20. The leak ran for
days *with presence publication already disabled*.

Two things follow, and both matter:

1. **The server-side routing restriction is the only reliable fix.** The
   client-side path depends on the RLS-URI key, which remains unverified —
   so it cannot be *assumed* to work either.
2. **Never infer that a leak is fixed from a config setting.** Only the
   egress sweep proves it, and only while a client is actually registered —
   with no clients connected the sweep reads clean whether or not the leak
   exists. Check the sweep *with a client online*.

**Note:** the `[presence-server]` block in `config/flexisip.conf` is
unrelated to this leak. It runs no presence server — it only suppresses a
deprecation warning. Deleting it does **not** fix the phone-home.

### Related: verify you are not an open relay

The same sweep is a toll-fraud regression check. Internet scanners probe SIP
proxies with premium-rate numbers under many dial prefixes (e.g.
`00<number>`, `9011<number>`, `900<number>`). On a correctly authenticating
proxy these appear **only** in *received* requests, never in `Sending SIP
request` lines. **If a phone number ever appears in the "Sending" list, you
have an open relay and a financial emergency.**

## Required hardening the shipped config assumes

These are **not optional extras** — the shipped configuration actively
depends on them.

- **fail2ban (or equivalent) is REQUIRED.** `[module::DoSProtection]` is
  disabled in this stack because the in-container iptables-based module
  cannot work under Docker; the config delegates rate limiting to an
  external control. If you skip it there is **no rate limiting at any
  layer** — one live deployment accumulated ~50,000 `401 Unauthorized`
  scanner hits this way.
- **A host firewall.** Containers publish to loopback where possible, but
  the host itself needs an INPUT policy. Sequence firewall changes
  carefully on remote hosts: add loopback, `ESTABLISHED,RELATED`, and your
  SSH rule *before* setting a default DROP, and verify from a second
  session.
- **Check the *effective* SSH config, not the file.** Cloud-init images
  frequently override `PasswordAuthentication no` via
  `/etc/ssh/sshd_config.d/*.conf`, and the **first** directive wins.
  Verify with `sshd -T | grep -E 'passwordauthentication|permitrootlogin'`,
  and check whether root's password is set (`passwd -S root` → `P` means
  set, `L` means locked).
- **Restrict the credential files:** `chmod 600 .env config/users.conf`.
  HA1 hashes are not plaintext passwords but are offline-crackable.
- **Change the default database credentials.** See "Default credentials"
  below.

## Default credentials — change these

This stack ships **default, guessable** datastore credentials so it starts
out of the box:

- MariaDB root and application passwords are both the literal string
  `flexisip` (`docker-compose.yml`, and the conference server's
  `database-connection-string`).
- Redis runs with **no authentication** (`redis-auth-password` is commented
  out in the conference config).

Both are published to `127.0.0.1` only, which is the mitigation. But the
proxy and conference containers run with `network_mode: host`, so **any
host process or host-networked container can reach them without
credentials**, and a container escape or SIP-parser exploit reaches them
immediately. Redis holds all SIP registrations and can be used to
manipulate call routing.

⚠️ **Changing these is a deliberate operator procedure, not a `git pull`.**
This repo does not ship changed values because (a) the entrypoints
intentionally perform **no runtime substitution**, so `${VAR}` in a `.conf`
file is *not* expanded, and (b) changing the literal value here would break
every existing deployment's database on update. Change them locally, in
step, across the compose file, the conference config, and the running
database.

## Trusting the EKT license

Upstream code declares the EKT plugin under GNU AGPLv3. The upstream
CMake option for EKT (`ENABLE_EKT_SERVER`) carries this note:

> For customers under a proprietary license, this functionality is under
> a specific license.

This means Belledonne may require a commercial license for some deployment
scenarios (e.g. proprietary redistribution of binaries or hosted service
without source disclosure). For AGPL-3.0 self-hosting — which is what this
repository is built for — the plugin is freely usable. **This is not legal
advice**; consult a lawyer if in doubt.
