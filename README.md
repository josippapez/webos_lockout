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
| Hosts blocklist | Bind-mounts a modified `/etc/hosts` sending 40 LG telemetry names to `0.0.0.0` / `::1` |
| Hardcoded IPs | `iptables` chain `LG_LOCKOUT` drops `156.147.69.32` and `54.186.247.229`, which bypass DNS |
| Usage data | Sets `usageCare`, `dbgLogUpload`, `faultLogUpload` to `false` in `/var/luna/preferences/option` |

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
- **Hosts files cannot wildcard.** Only the names in `domains.txt` are blocked.
  A new LG subdomain needs adding by hand.
- **AWS IoT MQTT is not blocked.** Push uses per-device certificates against
  device-specific `*.amazonaws.com` endpoints. The TV currently holds
  connections to `ec2-63-33-228-172.eu-west-1` and `ec2-34-242-48-77.eu-west-1`.
  Blocking those needs router-level rules against AWS ranges, which would break
  unrelated services.
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
deploy.sh      macOS-side installer/runner
domains.txt    hostnames to block (edit this, then re-install)
ips.txt        DNS-bypassing IPs to drop
tv/lockout.sh  the boot script, installed as init.d/20-lg-lockout
tv/verify.sh   read-only state report
tv/undo.sh     reverts everything
```

`run-parts` runs `init.d` in lexical order and skips filenames containing dots,
hence the extensionless `20-lg-lockout`, which sorts before the existing
`restore_dts25` audio hook.

## Sources

- [LG TV Block Mini-How-to, Level1Techs](https://forum.level1techs.com/t/lg-tv-block-mini-how-to/255178)
- [webosbrew/webos-homebrew-channel](https://github.com/webosbrew/webos-homebrew-channel)
