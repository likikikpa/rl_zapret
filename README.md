# zapret for Rocket League + Discord (Russia)

Based on [Flowseal/zapret-discord-youtube 1.10.4](https://github.com/Flowseal/zapret-discord-youtube/releases/tag/1.10.4).
Works on Windows 10 (1803 or newer) and Windows 11. Not an official Flowseal build.

## Start

1. Download the folder and unpack it to a **short** path **without Cyrillic
   letters**, for example `C:\zapret`. Paths longer than 57 characters break
   the longest strategies (cmd.exe line limit); the launcher warns about this.
   Close any other zapret, GoodbyeDPI or similar tool.
2. Double-click **`Rocket League.cmd`** and accept the Windows UAC prompt.
   It starts zapret with the saved strategy (default `general (ALT9).bat`)
   and then shows a menu.
3. Restart Discord and Rocket League.

Only one strategy can run at a time. The launcher stops the old one first.

## Launcher menu

| Option | What it does |
| --- | --- |
| 1 | Start / restart zapret with the selected strategy |
| 2 | Choose another `general*.bat` strategy (saved for next time) |
| 3 | Stop zapret |
| 4 | Test all strategies (upstream tester) to find one where Discord works |
| 5 | Switch the Discord voice fake packet (steamcommunity / dbankcloud) |
| 6 | Rocket League login mode: Direct (default) or DPI |
| 7 | Rocket League network diagnostics (DNS + HTTPS to PsyNet/Epic) |
| 8 | Open `service.bat` (Game Filter, IPSet, install as Windows service, diagnostics) |

## Discord does not work

Try these in order, restarting Discord after each one:

1. **Option 4** - run the standard tests on all strategies, then pick the
   one where the Discord lines pass with **option 2**. Which ALT works
   depends on your provider; there is no single best one.
2. Voice stuck on "RTC Connecting": **option 5**, switch the Discord fake.
3. Still nothing: option 8 -> `5. IPSet Filter` (press it until it shows
   `loaded`) and/or `4. Game Filter`. Both are off by default because they
   send much more traffic through zapret, which can add latency.

## Rocket League

Every strategy contains three extra rules placed before the general ones:

- **RL login (TCP/QUIC)** for `lists/list-rocket-league.txt`. In Direct mode
  this traffic is passed through untouched; in DPI mode (option 6) it gets the
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
