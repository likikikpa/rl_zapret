# zapret for Rocket League + Discord (Russia)

Based on [Flowseal/zapret-discord-youtube 1.10.4](https://github.com/Flowseal/zapret-discord-youtube/releases/tag/1.10.4).
Works on Windows 10 (1803 or newer) and Windows 11. Not an official Flowseal build.

## Start

1. Download the folder and unpack it to a **short** path **without Cyrillic
   letters**, for example `C:\zapret`. Paths longer than 57 characters break
   the longest strategies (cmd.exe line limit); the launcher warns about this.
   Close any other zapret, GoodbyeDPI or similar tool.
2. Double-click **`Rocket League.cmd`** and accept the Windows UAC prompt.
   On the first start it runs **auto-select** (3-6 minutes): every strategy
   is tested on your connection and the one that works best for Discord is
   saved and started. Later starts use the saved strategy right away.
3. Restart Discord and Rocket League.

## Auto-select the strategy for your provider

Double-click **`Auto Select Strategy.cmd`** (or option 4 in the launcher) at any
time, e.g. after your provider changes something. It:

1. checks the sites without zapret (to show what is blocked),
2. starts each `general*.bat` in turn and downloads full pages from Discord
   (main site, app, API, gateway, CDN, updates), YouTube and Rocket League /
   Epic. Full downloads catch the "freezes after 16-20 KB" DPI blocking that
   simple header checks miss,
3. re-tests the 3 best candidates to rule out a lucky single run,
4. saves the winner (Discord first, then YouTube and Rocket League, then speed),
   starts it and writes a report to `utils\test results\`.

Discord **voice** (UDP) cannot be tested automatically. If voice hangs on
"RTC Connecting" after auto-select, use launcher option 6.

Only one strategy can run at a time. The launcher stops the old one first.

## Launcher menu

| Option | What it does |
| --- | --- |
| 1 | Start / restart zapret with the selected strategy |
| 2 | Choose another `general*.bat` strategy (saved for next time) |
| 3 | Stop zapret |
| 4 | **Auto-select** the best strategy for your provider |
| 5 | Manual strategy tester (detailed upstream tests) |
| 6 | Switch the Discord voice fake packet (steamcommunity / dbankcloud) |
| 7 | Rocket League login mode: Direct (default) or DPI |
| 8 | Rocket League network diagnostics (DNS + HTTPS to PsyNet/Epic) |
| 9 | Open `service.bat` (Game Filter, IPSet, install as Windows service, diagnostics) |
| 10 | Network Doctor (see below) |

## Discord does not work

Try these in order, restarting Discord after each one:

1. **Option 4** (auto-select). Which ALT works depends on your provider;
   there is no single best one.
2. Voice stuck on "RTC Connecting": **option 6**, switch the Discord fake.
3. Still nothing: option 9 -> `5. IPSet Filter` (press it until it shows
   `loaded`) and/or `4. Game Filter`. Both are off by default because they
   send much more traffic through zapret, which can add latency.

## High ping / lag: Network Doctor

Double-click **`Network Doctor.cmd`** (or launcher option 10). In 1-2 minutes it
tells you *where* the lag comes from and what to do about it:

- **Ping by segment**, all measured at the same time:
  PC -> router -> ISP -> Moscow -> Frankfurt/Stockholm. Lag that starts at the
  router is your Wi-Fi/cable/PC; lag that starts at the ISP hop is the ISP line;
  a big jump between Moscow and Frankfurt is the ISP's route to Europe (where
  Rocket League EU servers are). The Frankfurt value is about the best EU ping
  your connection can give.
- **Hardware**: Wi-Fi vs cable, signal strength, 2.4 vs 5 GHz, USB Wi-Fi /
  Ethernet adapters (port advice), Ethernet stuck at 100 Mbps or half duplex
  (damaged cable), packet errors (bad cable/port/driver), disconnects in the
  last 7 days, devices with driver problems.
- **Software**: VPN in the path, programs downloading in the background
  (Steam, torrents, cloud sync), zapret Game Filter.
- **Bufferbloat**: ping while the line is fully loaded by a download (Russian
  speed-test servers). A big rise means downloads at home cause lag -> enable
  SQM/QoS on the router or limit download speeds.

Results are ranked MAJOR / LIKELY / MINOR with a fix for each and saved in
`utils\test results\`. Run it in the evening and in the morning: if only the
evening is bad, the ISP is congested.

At the end it offers **safe, reversible** fixes only: turning off network power
saving (USB selective suspend, PCIe link power saving, Wi-Fi power saving,
Energy-Efficient/Green Ethernet, "allow Windows to turn off this device").
Option 2 in Network Doctor undoes them. It deliberately does **not** apply
"TCP optimizer" registry tweaks (Nagle, NetworkThrottlingIndex, ...): they do
nothing for Rocket League, which uses UDP.

## Rocket League

Every strategy contains three extra rules placed before the general ones:

- **RL login (TCP/QUIC)** for `lists/list-rocket-league.txt`. In Direct mode
  this traffic is passed through untouched; in DPI mode (option 7) it gets the
  strategy's own TCP desync. Try DPI mode if the game cannot log in.
- **RL game UDP** on ports `7000-10000,15000-15999,21000-21999`. Only the
  first packets of each flow get a fake (`--dpi-desync-cutoff=d4`), so
  in-match traffic is not delayed. Works without Game Filter / IPSet.

Advanced options (run in PowerShell inside this folder, then restart zapret):

```powershell
# fragmented UDP fakes (some networks drop fragments)
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -UdpMode Fragment
# another fake payload from bin\
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -Payload quic_initial_steamcommunity_com.bin
# back to defaults
powershell -NoProfile -ExecutionPolicy Bypass -File .\utils\configure-rocket-league.ps1 -AuthMode Direct -UdpMode Fake -Payload quic_initial_4pda_to.bin
```

The script rewrites all `general*.bat` files and keeps the rules identical in each.

## Windows service

`service.bat` -> `Install Service` runs a strategy at boot. The service stores
its own copy of the command line, so reinstall it after changing the login
mode or UDP settings. While the service runs, the launcher will not start a
second copy.

Do not use service.bat's "Check for Updates" download: Flowseal releases do not
contain the Rocket League rules.
