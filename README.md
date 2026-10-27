# webos_lockout

Blocks LG telemetry egress on a rooted webOS TV. Runs at every boot via the
Homebrew Channel's `init.d` hook.

Built and verified against: **OLED77C51LA**, Rockhopper 10.3.1-3006, kernel
`5.4.268-329.ptl4tv.5` aarch64.

## Usage

```sh
ssh-add --apple-use-keychain ~/.ssh/tv-rooted-c5   # once per session
./deploy.sh install    # copy to TV + register boot hook
./deploy.sh apply      # activate now without rebooting
./deploy.sh verify      # report state of every control
./deploy.sh status     # what's installed
./deploy.sh logs       # tail the on-TV log
./deploy.sh undo       # revert everything
```

Target TV comes from the `c5` alias in `~/.ssh/config`. Override with
`TV_HOST=other ./deploy.sh …`.

## What it does

| Stage | Mechanism |
|---|---|
| Hosts blocklist | Bind-mounts a modified `/etc/hosts` sending 3749 LG telemetry names to `0.0.0.0` / `::1` |
| Hardcoded IPs | `iptables` chain `LG_LOCKOUT` drops `156.147.69.32` and `54.186.247.229`, which bypass DNS |
| Usage data | Sets `usageCare`, `dbgLogUpload`, `faultLogUpload` to `false` in `/var/luna/preferences/option` |
| Daemons | Bind-mounts a no-op over `remotelogger`, `service-logger`, `contentminer`, `nudge`, `acr2` (viewing tracking) and `sportsalarm`, then stops them. `admanager`/`adoverlay-service` stay, because LG's Home needs them |

The hosts layer works because this firmware's `/etc/nsswitch.conf` reads
`hosts:files mdns myhostname mdns4_minimal [NOTFOUND=return] dns`, so
`getaddrinfo` consults the hosts file before DNS. Confirmed by observing
`lgsmartad.com` resolve to `::1` instead of `165.244.150.53` under the mount.

## What was already handled, and is only verified here

- ACR is fully denied in `/var/luna/preferences/eula` (`acrAllowed`,
  `acrOnAllowed`, `acrGdprAllowed`, `acrAdAllowed` all `false`), as are
  `thirdPartySharingAllowed`, `customAdAllowed`, `marketingOnAllowed`,
  `voiceAllowed`, `voice2Allowed`, `remoteDiagAllowed`.
- Homebrew's `startup.sh:113-119` already bind-mounts read-only stubs over
  `/tmp/rdxd`, `/tmp/uploadd`, `/var/spool/rdxd` and
  `/var/spool/uploadd/{pending,uploaded}`, killing the offline-spool-then-upload
  path. `verify.sh` checks these rather than re-doing them.

## Deliberate omissions

- **OTA update hosts stay reachable.** `su.lge.com`, `su-ssl.lge.com`,
  `snu.lge.com`, `nsu.lge.com` are not blocked, so firmware updates can be
  reviewed and applied by choice. Homebrew's own
  `/var/luna/preferences/webosbrew_block_updates` flag covers them if wanted.
- **Voice keys in `option` are not touched.** `inputDevicesSupportStatus.voice`
  is a remote-hardware capability flag, not a consent toggle. Voice consent is
  `voiceAllowed`/`voice2Allowed` in the EULA file, already `false`, and
  `lgsmartweb.com` is blocked.

## Known limits

- **No IPv6 filtering.** This kernel ships no `ip6_tables` module, so
  `ip6tables` cannot initialise a filter table. Both hardcoded LG endpoints are
  IPv4, so nothing is lost today, but an IPv6-only endpoint could not be dropped.
- **Hosts files cannot wildcard**, which matters more than it sounds. `sdx`
  stores the bare domain in
  `/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf` and prepends the TV's
  region code at runtime, so a Croatian set reaches `hr.nextlgsdp.com` even
  with `nextlgsdp.com` blocked. `prefixes.txt` therefore enumerates the prefix
  space (249 ISO 3166-1 alpha-2 codes from `/usr/share/zoneinfo/iso3166.tab`,
  plus the regional and lab prefixes seen on-device) and `lockout.sh` expands it
  against every base in `wildcard-bases.txt`. A new LG *base* domain still needs
  adding by hand.
- **AWS IoT MQTT is not blocked.** Push uses per-device certificates against
  device-specific `*.amazonaws.com` endpoints. Blocking those needs router-level
  rules against AWS ranges, which would break unrelated services. Note that most
  AWS connections a webOS TV holds are *not* LG: mapping sockets to owning
  processes via `/proc` showed them belonging to the `netflix` app, `WebAppMgr`
  and `com.webos.chrom` (Google FCM on port 5228). Check ownership before
  assuming a connection is telemetry.
- **Telemetry processes keep running.** `sdx`, `rdxd`, `uploadd`, `admanager`,
  `iot-client` and `trigger_thinq` are not killed, only denied egress and
  writable spool space.
- **A factory reset wipes all of this.** Only router-level blocking survives one.
- **Prefs are edited on disk, not through `luna-send`,** which returns nothing
  over SSH (no `/run/luna-service2` socket in a non-login shell). This was
  tested rather than assumed: `usageCare` was set back to `true`, the hosts
  mount and iptables chain were removed, and after a reboot all three came back.
  `usageCare` still read `false` at 677s uptime, so `settingsservice` does not
  rewrite it during a session.

## Layout

```
deploy.sh            macOS-side installer/runner
scan-prefixes.sh     re-scan the region prefix space for new endpoints
domains.txt          explicit hostnames (192 entries)
wildcard-bases.txt   base domains whose every subdomain must be blocked (7)
prefixes.txt         region/infra prefixes expanded against bases (269)
patterns.txt         hostname templates where {p} is the region prefix (6)
ips.txt              DNS-bypassing IPs to drop
tv/lockout.sh        the boot script, installed as init.d/20-lg-lockout
tv/verify.sh         read-only state report
tv/sockets.py        maps external connections to owning processes
tv/undo.sh           reverts everything
```

`run-parts` runs `init.d` in lexical order and skips filenames containing dots,
hence the extensionless `20-lg-lockout`, which sorts before the existing
`restore_dts25` audio hook.

## Coverage audit

Run 2026-09-09 against webOS 10.3.1. Three independent methods, then merged.

1. **On-device sweep.** grep over `/usr/sbin`, `/usr/bin`, `/usr/lib`,
   `/usr/palm`, `/etc`, `/var/luna` and `/mnt/lg/cmn_data` found **2568 distinct
   LG hostnames** referenced in binaries and config. 82 were uncovered,
   including `videoacr.lgtvcommon.com` and `videoads.lgtvcommon.com`.
2. **Region brute-force.** All 676 two-letter prefixes queried against
   `nextlgsdp.com`: **253 resolve.** Four were absent from the ISO-derived list
   (`eu`, `te`, `xa`, `xb`) and are now included. No three-letter shape exists
   (`hrv.nextlgsdp.com` and friends do not resolve), so the region space is
   fully mapped. `scan-prefixes.sh` repeats this check on demand.
3. **Community blocklists**, fetched and merged: 691 LG hostnames from
   hugobatista, Perflyst, athimannil and the wassname gist, of which 583 are
   produced by prefix expansion and 108 needed listing explicitly.
4. **Reddit**, reached with `agent-browser` using a persistent profile in
   headed mode (the default headless fingerprint gets "blocked by network
   security"). r/pihole pointed to **HaGeZi's LG webOS tracker list**, 341
   entries, which was the one maintained source the other four had not
   surfaced. It contributed the Akamai `*.edgekey.net` CNAME targets for the
   `ngfts` endpoints and the compound infra prefixes (`eic-qt2`, `qt2-aic`).

Per-base regional endpoint counts, measured by DNS enumeration over 269
prefixes:

| Base | Live regional endpoints |
|---|---|
| `nextlgsdp.com` | 248 |
| `lgtvsdp.com` | 186 |
| `lgappstv.com` | 162 |
| `lgsmartad.com` | 160 |
| `lgthinq.com` | 153 |
| `lgtviot.com` | 2 |
| `lgtvcommon.com` | 1 |

Both the HaGeZi list and the merged community union now diff clean against the
generated blocklist, with one exception: `h4g3z1-native.lgwebos.web.app` is
HaGeZi's own list-verification canary, not an LG endpoint, so it is left out.

**Result:** all six LG telemetry daemons (`sdx`, `rdxd`, `uploadd`,
`admanager`, `iot-client`, `trigger_thinq`) hold zero external sockets.
`verify.sh` section 8 asserts this on every run.

## Sources

- [LG TV Block Mini-How-to, Level1Techs](https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178)
- [webosbrew/webos-homebrew-channel](https://github.com/webosbrew/webos-homebrew-channel)
- [hugobatista/lg-tv-ad-block](https://github.com/hugobatista/lg-tv-ad-block)
- [Perflyst/PiHoleBlocklist](https://github.com/Perflyst/PiHoleBlocklist)
- [athimannil/webos-pihole-blocklists](https://github.com/athimannil/webos-pihole-blocklists)
- [hagezi/dns-blocklists — native.lgwebos.txt](https://github.com/hagezi/dns-blocklists)
