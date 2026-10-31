"""Validate actual BAT arguments using winws --dry-run, without loading WinDivert."""
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
shell32 = ctypes.WinDLL('shell32', use_last_error=True)
shell32.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
kernel32.LocalFree.argtypes = [ctypes.c_void_p]


def split_windows(command):
    count = ctypes.c_int()
    ptr = shell32.CommandLineToArgvW('winws.exe ' + command, ctypes.byref(count))
    if not ptr:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return [ptr[i] for i in range(1, count.value)]
    finally:
        kernel32.LocalFree(ptr)


def validate(file, tcp, udp):
    lines = file.read_text(encoding='utf-8-sig').splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith('start ') and 'winws.exe' in line)
    command = []
    end = start
    while True:
        line = lines[end].strip()
        continued = line.endswith('^')
        if continued:
            line = line[:-1].rstrip()
        line = line.replace('^!', '!')  # cmd.exe escaping in upstream FAKE TLS AUTO
        assert '^' not in line, f'{file.name}:{end + 1}: stray continuation character'
        command.append(line)
        if not continued:
            break
        end += 1
    assert not any(line.lstrip().startswith('--') for line in lines[end + 1:]), 'Rules outside the start command'
    assert lines[start + 1].startswith('--comment=RL_AUTH_TCP '), 'Auth rule must be first'
    assert lines[start + 2].startswith('--comment=RL_AUTH_QUIC '), 'QUIC rule must be second'
    assert lines[start + 3].startswith('--comment=RL_GAME_UDP '), 'Game rule must precede GameFilter'
    expanded = ' '.join(command)
    for name, value in {'BIN': str(ROOT / 'bin') + '\\', 'LISTS': str(ROOT / 'lists') + '\\',
                        'GameFilterTCP': tcp, 'GameFilterUDP': udp}.items():
        expanded = expanded.replace(f'%{name}%', value)
    expanded = expanded.replace('%~n0', file.stem)
    assert len(expanded) <= 8191, 'Expanded command exceeds the cmd.exe length limit'
    joined = expanded.split('winws.exe"', 1)[1].strip()
    assert not re.search(r'%\w+%', joined), 'Unexpanded batch variable'
    args = split_windows(joined)
    assert args.count('--comment=RL_AUTH_TCP') == 1
    assert args.count('--comment=RL_AUTH_QUIC') == 1
    assert args.count('--comment=RL_GAME_UDP') == 1
    game = args[args.index('--comment=RL_GAME_UDP'):]
    game = game[:game.index('--new')]
    assert '--dpi-desync-cutoff=d4' in game
    env = dict(os.environ, __COMPAT_LAYER='RunAsInvoker')
    result = subprocess.run([str(ROOT / 'bin' / 'winws.exe'), '--dry-run', *args],
                            cwd=ROOT / 'bin', env=env, capture_output=True, timeout=30)
    detail = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    assert result.returncode == 0 and 'command line parameters verified' in detail, detail
    return {'strategy': file.name, 'tcp': tcp, 'udp': udp, 'passed': True}


if __name__ == '__main__':
    checks = []
    for file in sorted(ROOT.glob('general*.bat')):
        for tcp, udp in [('12', '12'), ('1024-65535', '1024-65535')]:
            try:
                checks.append(validate(file, tcp, udp))
            except Exception as exc:
                print(f'FAIL {file.name}: {exc}', file=sys.stderr)
                sys.exit(1)
    destination = ROOT / 'utils' / 'test results' / 'rocket-league-validation.json'
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(checks, indent=2) + '\n', encoding='utf-8')
    print(f'PASS: {len(checks)} native dry-run checks across {len(checks) // 2} launchers.')
