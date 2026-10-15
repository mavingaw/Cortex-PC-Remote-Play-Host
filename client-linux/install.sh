#!/usr/bin/env bash
#
# Razer PC Remote Play client installer for SteamOS, Bazzite and other Linux desktops.
#
# One line, from Desktop Mode (Konsole):
#   curl -fsSL https://raw.githubusercontent.com/mavingaw/Cortex-PC-Remote-Play-Host/main/client-linux/install.sh | bash
#
# What it does:
#   1. Downloads the AppImage to ~/Applications
#   2. Installs an icon and a desktop entry (app menu in Desktop Mode)
#   3. Adds it to Steam as a non-Steam game so it shows up in Game Mode / Big Picture
#
# Environment overrides:
#   RPR_BASE_URL     where to fetch files from (default: this repo on GitHub, main branch)
#   RPR_NO_STEAM=1   skip the Steam shortcut
#   RPR_UNINSTALL=1  remove the files this script installed (the Steam shortcut must be removed in Steam)

set -euo pipefail

APP_NAME="Razer PC Remote Play"
BASE_URL="${RPR_BASE_URL:-https://raw.githubusercontent.com/mavingaw/Cortex-PC-Remote-Play-Host/main/client-linux}"
APPIMAGE_URL="$BASE_URL/dist/RazerPCRemotePlay-x86_64.AppImage"
SUMS_URL="$BASE_URL/dist/SHA256SUMS"
ICON_URL="$BASE_URL/razer-pc-remote-play.png"

INSTALL_DIR="$HOME/Applications"
APPIMAGE="$INSTALL_DIR/RazerPCRemotePlay-x86_64.AppImage"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON="$ICON_DIR/razer-pc-remote-play.png"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP="$DESKTOP_DIR/razer-pc-remote-play.desktop"

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "${RPR_UNINSTALL:-0}" = 1 ]; then
  rm -f "$APPIMAGE" "$ICON" "$DESKTOP"
  log "Removed $APP_NAME files. Remove the shortcut from Steam's library if you added one."
  exit 0
fi

command -v curl >/dev/null || fail "curl is required"
[ "$(uname -m)" = "x86_64" ] || fail "only x86_64 builds are published (this machine is $(uname -m))"

# ----------------------------------------------------------------------------- AppImage
log "Downloading $APP_NAME"
mkdir -p "$INSTALL_DIR"
# Resume a partial download and retry on dropped connections (the file is large).
curl -fL --progress-bar --retry 5 --retry-delay 3 --retry-all-errors -C - \
     -o "$APPIMAGE.part" "$APPIMAGE_URL"
if command -v sha256sum >/dev/null && expected="$(curl -fsSL "$SUMS_URL" 2>/dev/null | awk '{print $1}')" && [ -n "$expected" ]; then
  actual="$(sha256sum "$APPIMAGE.part" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail "checksum mismatch: expected $expected, got $actual"
fi
mv -f "$APPIMAGE.part" "$APPIMAGE"
chmod +x "$APPIMAGE"
log "Installed $APPIMAGE"

# ----------------------------------------------------------------------------- icon + desktop entry
mkdir -p "$ICON_DIR" "$DESKTOP_DIR"
curl -fsSL -o "$ICON" "$ICON_URL"
cat > "$DESKTOP" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Stream games from a PC running Razer PC Remote Play Host
Exec=$APPIMAGE
Icon=$ICON
Terminal=false
Categories=Game;
Keywords=moonlight;streaming;razer;cortex;
DESKTOP_EOF
chmod +x "$DESKTOP"
command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
log "Installed desktop entry $DESKTOP"

# ----------------------------------------------------------------------------- Steam shortcut
if [ "${RPR_NO_STEAM:-0}" = 1 ]; then
  log "Skipping Steam shortcut (RPR_NO_STEAM=1)"
  exit 0
fi

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$1"; }

steam_running() { pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; }

if steam_running; then
  # Steam is up: hand it the desktop entry, exactly what "Add to Steam" in Dolphin does.
  if command -v steamos-add-to-steam >/dev/null; then
    steamos-add-to-steam "$DESKTOP"
  else
    steam_cmd="$(command -v steam || true)"
    [ -z "$steam_cmd" ] && command -v flatpak >/dev/null && flatpak info com.valvesoftware.Steam >/dev/null 2>&1 && steam_cmd="flatpak run com.valvesoftware.Steam"
    [ -n "$steam_cmd" ] || fail "Steam is running but no 'steam' command was found. Add $DESKTOP to Steam manually."
    $steam_cmd -ifrunning "steam://addnonsteamgame/$(urlencode "$DESKTOP")"
  fi
  log "Added '$APP_NAME' to Steam. It is in your library under Non-Steam, and in Game Mode / Big Picture."
  exit 0
fi

# Steam is not running: write the shortcut straight into shortcuts.vdf for every Steam user.
command -v python3 >/dev/null || fail "python3 is required to write Steam shortcuts while Steam is closed. Start Steam and re-run."
added=0
for steam_root in "$HOME/.steam/steam" "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
  [ -d "$steam_root/userdata" ] || continue
  for cfg in "$steam_root"/userdata/*/config; do
    [ -d "$cfg" ] || continue
    case "$cfg" in */userdata/0/config) continue ;; esac
    python3 - "$cfg/shortcuts.vdf" "$APP_NAME" "$APPIMAGE" "$INSTALL_DIR" "$ICON" "$DESKTOP" <<'PY'
import os, struct, sys, zlib

path, name, exe, start_dir, icon, desktop = sys.argv[1:7]

# --- minimal binary VDF (KeyValues) reader/writer -----------------------------------
def read_map(buf, pos):
    out = {}
    while True:
        t = buf[pos]; pos += 1
        if t == 0x08:
            return out, pos
        end = buf.index(b"\x00", pos); key = buf[pos:end].decode("utf-8", "replace"); pos = end + 1
        if t == 0x00:
            out[key], pos = read_map(buf, pos)
        elif t == 0x01:
            end = buf.index(b"\x00", pos); out[key] = buf[pos:end].decode("utf-8", "replace"); pos = end + 1
        elif t == 0x02:
            out[key] = struct.unpack_from("<i", buf, pos)[0]; pos += 4
        else:
            raise ValueError("unknown vdf type %r" % t)

def write_map(d):
    b = bytearray()
    for k, v in d.items():
        if isinstance(v, dict):
            b += b"\x00" + k.encode() + b"\x00" + write_map(v)
        elif isinstance(v, int):
            b += b"\x02" + k.encode() + b"\x00" + struct.pack("<i", v)
        else:
            b += b"\x01" + k.encode() + b"\x00" + str(v).encode() + b"\x00"
    b += b"\x08"
    return bytes(b)

shortcuts = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, "rb") as f:
        buf = f.read()
    top, _ = read_map(buf, 0)
    shortcuts = top.get("shortcuts", {})

for entry in shortcuts.values():
    if isinstance(entry, dict) and entry.get("AppName", entry.get("appname")) == name:
        print("Steam shortcut already present in", path)
        sys.exit(0)

appid = zlib.crc32((f'"{exe}"' + name).encode()) | 0x80000000
appid = struct.unpack("<i", struct.pack("<I", appid))[0]
idx = str(max([int(k) for k in shortcuts if k.isdigit()] + [-1]) + 1)
shortcuts[idx] = {
    "appid": appid,
    "AppName": name,
    "Exe": f'"{exe}"',
    "StartDir": f'"{start_dir}"',
    "icon": icon,
    "ShortcutPath": desktop,
    "LaunchOptions": "",
    "IsHidden": 0,
    "AllowDesktopConfig": 1,
    "AllowOverlay": 1,
    "OpenVR": 0,
    "Devkit": 0,
    "DevkitGameID": "",
    "DevkitOverrideAppID": 0,
    "LastPlayTime": 0,
    "FlatpakAppID": "",
    "tags": {},
}
if os.path.exists(path):
    os.replace(path, path + ".bak")
with open(path, "wb") as f:
    f.write(write_map({"shortcuts": shortcuts}))
print("Added Steam shortcut to", path)
PY
    added=$((added + 1))
  done
done

if [ "$added" -gt 0 ]; then
  log "Added '$APP_NAME' to Steam for $added user(s). Start Steam: it is in your library under Non-Steam, and in Game Mode / Big Picture."
else
  log "No Steam user data found. Start Steam once, then re-run this script, or add $DESKTOP via 'Add a Non-Steam Game'."
fi
