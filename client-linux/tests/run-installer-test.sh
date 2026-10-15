#!/usr/bin/env bash
#
# Exercises install.sh in a scratch HOME against a file:// copy of this directory:
# Steam-closed path (shortcuts.vdf written next to an existing entry, artwork named
# after the same app id), idempotent rerun, Steam-running path with stub commands,
# first-run defaults, and uninstall. Needs python3 and curl; no network.
#
#   tests/run-installer-test.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -s "$ROOT/dist/RazerPCRemotePlay-x86_64.AppImage" ] || { echo "dist/RazerPCRemotePlay-x86_64.AppImage missing" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'pkill -x steamwebhelper 2>/dev/null || true; rm -rf "$WORK"' EXIT
export RPR_BASE_URL="file://$ROOT"
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

vdf_entries() {   # print "AppName|appid_unsigned" per entry
  python3 - "$1" <<'PY'
import struct, sys
buf = open(sys.argv[1], "rb").read()
def rm(pos):
    out = {}
    while True:
        t = buf[pos]; pos += 1
        if t == 8: return out, pos
        e = buf.index(b"\x00", pos); k = buf[pos:e].decode(); pos = e + 1
        if t == 0: out[k], pos = rm(pos)
        elif t == 1: e = buf.index(b"\x00", pos); out[k] = buf[pos:e].decode(); pos = e + 1
        elif t == 2: out[k] = struct.unpack_from("<i", buf, pos)[0]; pos += 4
top, _ = rm(0)
assert buf.endswith(b"\x08\x08")
for v in top["shortcuts"].values():
    print(f"{v['AppName']}|{v['appid'] & 0xffffffff}")
PY
}

echo "== Steam closed"
export HOME="$WORK/closed"
CFG="$HOME/.steam/steam/userdata/555/config"
mkdir -p "$CFG" "$HOME/.steam/steam/userdata/0/config"
python3 - "$CFG/shortcuts.vdf" <<'PY'
import struct, sys
def s(k, v): return b"\x01" + k.encode() + b"\x00" + v.encode() + b"\x00"
def i(k, v): return b"\x02" + k.encode() + b"\x00" + struct.pack("<i", v)
entry = (b"\x000\x00" + i("appid", -123456) + s("AppName", "Other Game") + s("Exe", '"/bin/true"') + s("StartDir", '"/"')
         + s("icon", "") + s("ShortcutPath", "") + s("LaunchOptions", "") + i("IsHidden", 0) + i("AllowDesktopConfig", 1)
         + i("AllowOverlay", 1) + i("OpenVR", 0) + i("Devkit", 0) + s("DevkitGameID", "") + i("DevkitOverrideAppID", 0)
         + i("LastPlayTime", 0) + s("FlatpakAppID", "") + b"\x00tags\x00\x08" + b"\x08")
open(sys.argv[1], "wb").write(b"\x00shortcuts\x00" + entry + b"\x08\x08")
PY
bash "$ROOT/install.sh" > "$WORK/closed.log" 2>&1 || { cat "$WORK/closed.log"; exit 1; }
check "AppImage installed and executable" '[ -x "$HOME/Applications/RazerPCRemotePlay-x86_64.AppImage" ]'
check "desktop entry written"              'grep -q "^Exec=" "$HOME/.local/share/applications/razer-pc-remote-play.desktop"'
check "icon installed"                     '[ -s "$HOME/.local/share/icons/hicolor/256x256/apps/razer-pc-remote-play.png" ]'
check "first-run defaults seeded"          'grep -q "^razerdisplaymode=2" "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"'
check "existing shortcut preserved"        'vdf_entries "$CFG/shortcuts.vdf" | grep -q "^Other Game|"'
check "shortcut added"                     'vdf_entries "$CFG/shortcuts.vdf" | grep -q "^Razer PC Remote Play|"'
# shellcheck disable=SC2034  # used inside the eval string below
APPID="$(vdf_entries "$CFG/shortcuts.vdf" | awk -F'|' '/^Razer PC Remote Play/{print $2}')"
check "artwork named after shortcut appid" '[ -s "$CFG/grid/${APPID}p.png" ] && [ -s "$CFG/grid/${APPID}_hero.png" ] && [ -s "$CFG/grid/${APPID}_logo.png" ] && [ -s "$CFG/grid/${APPID}.png" ]'
check "userdata/0 untouched"               '[ -z "$(ls -A "$HOME/.steam/steam/userdata/0/config")" ]'
check "backup kept"                        '[ -s "$CFG/shortcuts.vdf.bak" ]'

echo "== rerun"
printf '[General]\nwidth=1280\n' > "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"
bash "$ROOT/install.sh" > "$WORK/rerun.log" 2>&1 || { cat "$WORK/rerun.log"; exit 1; }
check "shortcut not duplicated"            '[ "$(vdf_entries "$CFG/shortcuts.vdf" | grep -c "^Razer PC Remote Play|")" = 1 ]'
check "user settings left alone"           'grep -q "^width=1280" "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf" && ! grep -q razerdisplaymode "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"'

echo "== uninstall"
RPR_UNINSTALL=1 bash "$ROOT/install.sh" > "$WORK/uninstall.log" 2>&1 || { cat "$WORK/uninstall.log"; exit 1; }
check "AppImage removed"                   '[ ! -e "$HOME/Applications/RazerPCRemotePlay-x86_64.AppImage" ] && [ ! -e "$HOME/Applications/RazerPCRemotePlay.extracted" ]'
check "desktop entry and icon removed"     '[ ! -e "$HOME/.local/share/applications/razer-pc-remote-play.desktop" ] && [ ! -e "$HOME/.local/share/icons/hicolor/256x256/apps/razer-pc-remote-play.png" ]'

echo "== Steam running (stub commands)"
export HOME="$WORK/running"
CFG="$HOME/.steam/steam/userdata/777/config"
mkdir -p "$CFG" "$WORK/bin"
cp /bin/sleep "$WORK/bin/steamwebhelper"
printf '#!/bin/sh\necho "steamos-add-to-steam $*" >> "%s/calls.log"\n' "$WORK" > "$WORK/bin/steamos-add-to-steam"
chmod +x "$WORK/bin/"*
"$WORK/bin/steamwebhelper" 120 &
sleep 0.5
PATH="$WORK/bin:$PATH" bash "$ROOT/install.sh" > "$WORK/running.log" 2>&1 || { cat "$WORK/running.log"; exit 1; }
check "desktop entry handed to steamos-add-to-steam" 'grep -q "steamos-add-to-steam $HOME/.local/share/applications/razer-pc-remote-play.desktop" "$WORK/calls.log"'
check "shortcuts.vdf not written while Steam runs"  '[ ! -e "$CFG/shortcuts.vdf" ]'
check "artwork for candidate appids"                '[ "$(ls "$CFG/grid/"*_hero.png | wc -l)" = 4 ]'
pkill -x steamwebhelper || true

echo
if [ "$fails" = 0 ]; then echo "PASS: installer checks"; else echo "FAIL: $fails check(s)"; exit 1; fi
