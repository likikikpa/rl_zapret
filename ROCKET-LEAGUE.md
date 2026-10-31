# Zapret 1.10.4 with Rocket League rules

Updated 2026-10-31. Local modifications; not an official Flowseal build.

## Start

1. Close any other running zapret before switching strategies.
2. Double-click **Rocket League.cmd** and accept Windows UAC.
3. Restart Rocket League and test login, then an online match.
   This starts `general (ALT9-RL).bat`. The existing RL Optimizer still uses it.
4. To try another strategy, run any `general*.bat` as administrator.
   All 24 launchers include Rocket League rules, including new ALT12,
   ALT13, and EXP. Run only one strategy at a time.

## If login still fails

Run **Rocket League Login Mode.cmd**, select **2**, then close and restart
your strategy and Rocket League. This applies each ALT's own TCP DPI
strategy to the dedicated login list. Try ALT11, ALT12, or ALT13 too.
Select **1** to return to direct login (the initial setting).

Direct login selects Rocket League / Epic authentication traffic with an
early profile that applies no desync. It still follows Windows routing,
including any connected VPN. DPI login applies the selected ALT's TCP
strategy even though Epic domains are excluded by upstream's general list.
User exclusions in `lists/list-exclude-user.txt` are respected in both modes.

## If matches fail

The dedicated UDP rule works without GameFilter or IPSet membership.
Current ports: `7000-10000,15000-15999,21000-21999`.

- `7000-10000` includes ports **9046 and 9084** observed in this PC's match log.
- `15000-15999` includes region-ping ports observed in the same log.
- `21000-21999` retains the previous custom setup's coverage; it is not
  claimed to be a universal Epic port requirement.

Port-based filtering can affect other programs using these same ports.
The default UDP payload is the official release's `quic_initial_4pda_to.bin`.
Only the first three outgoing data packets receive desync (`cutoff=d4`).
This limits packet overhead; it does not promise lower latency or FPS gains.

Optional commands in PowerShell opened in this folder:

```powershell
# Try fragmented UDP (some networks drop fragments).
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -UdpMode Fragment
# Try another payload included in the official release.
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -Payload quic_initial_steamcommunity_com.bin
# Restore the initial UDP settings.
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -UdpMode Fake -Payload quic_initial_4pda_to.bin
```

Restart the strategy after every change. Each change affects all ALTs.
The script preserves existing custom web rules and writes literal arguments
so upstream service installation and strategy tests can still parse them.

## Diagnostics and limits

Run **Rocket League Diagnostics.cmd**. It checks DNS and HTTPS connectivity
to PsyNet, Epic, game content, and EOS S3 endpoints. HTTP 401/403/404 at an
API root can prove HTTPS transport; they do not prove successful login.
Reports go into `utils/test results`. No account tokens are copied.

The game log showed PsyNet timeouts, WebSocket disconnections, and at least
one failure to resolve `eos-general.s3.amazonaws.com`. Packet desync cannot
repair failed DNS. If Diagnostics reports DNS failure, check your current
connection's DNS. Epic's PC troubleshooting guide suggests public DNS.
No system DNS, firewall, hosts, VPN, or account settings were changed.

A VPN adapter was active during the initial HTTPS checks. Those checks
describe that route; they do not establish direct-ISP connectivity.
Successful login and stable matches must be verified in Rocket League.
The general upstream website tests cannot certify game login or UDP play.

## Windows service users

`service.bat` is updated to 1.10.4. If you already installed a zapret Windows
service, reinstall the chosen strategy with `service.bat` after changing
login/UDP modes: the service stores its own copy of the command line.
The existing GameFilter setting is preserved; dedicated RL UDP is independent
of it. IPSet was refreshed from Flowseal's official `ipset-service.txt`.

## Changes

- Official Flowseal 1.10.4 engine, profiles, manager, lists, and fake files.
- Rocket League login TCP/QUIC profiles precede broad IPSet/GameFilter rules.
- A game UDP rule also precedes broad filters in every launcher.
- Fixed the old ALT9's orphaned command by rebuilding from upstream.
- Rebuilt ALT9-RL and ALT9-CS2 on the new upstream ALT9. CS2 retains its
  dedicated `4380,27000-27100` UDP profile with a data-packet cutoff.
- Added login switching and diagnostics. Existing optimizer programs
  and their source files are preserved, not rebuilt or modified.

## Backup and source verification

The original folder is backed up under `.maintenance/backups/`.
The exact backup path is recorded in `.maintenance/last-backup.txt`.
To revert, stop zapret and copy the backup's original files back to this
folder. ALT12, ALT13, EXP and the new helper files were not in the old setup;
the clean original installation remains in the backup directory.

Official archive: `zapret-discord-youtube-1.10.4.zip`.

SHA256: `291af673bd0238506f9548e0e94ca0abf244000f4c9a06960544fb01c5f97b34`.

Verified against GitHub release asset metadata before extraction.
The archive, release metadata, and untouched upstream files are in
`.maintenance/downloads` and `.maintenance/upstream`.

## Research

- [Official release 1.10.4](https://github.com/Flowseal/zapret-discord-youtube/releases/tag/1.10.4).
- [Rocket League payload replacement report](https://github.com/Flowseal/zapret-discord-youtube/discussions/15425): a community report, not a universal fix. The reported 4pda payload is now included in the official release.
- [Different GameFilter results across users](https://github.com/Flowseal/zapret-discord-youtube/discussions/12765).
- [Engine parameters and profile behavior](https://github.com/bol-van/zapret/blob/master/docs/readme.en.md).
- [Epic PC troubleshooting](https://www.epicgames.com/help/c-182/c-39065013/a22691700?lang=en-US).
