# Razer PC Remote Play client for Linux handhelds

A Linux client for Razer PC Remote Play Host, built for the Lenovo Legion Go S
(SteamOS or Bazzite) but usable on any x86_64 Linux desktop.

The host in this repository is a fork of [Sunshine](https://github.com/LizardByte/Sunshine)
and speaks the standard Moonlight protocol. The stream itself (RTSP, video, audio,
input, pairing) is unchanged, so the right foundation for a client is
[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt), the same way the
[Android client](https://github.com/razerofficial/Razer-PC-Remote-Play-android) is
built on moonlight-android.

This directory follows the same approach as the Android client: upstream Moonlight
stays untouched, and the Razer-specific behaviour is a small patch series applied on
top of a pinned upstream commit. `build.sh` fetches, patches and compiles it.

## What the patch adds

The host accepts a few extra query parameters on `/launch`, `/resume` and `/pair`
that stock Moonlight never sends. The patch adds a **Razer PC Remote Play Host**
section to Moonlight's settings page and sends them:

| Setting | Launch parameter | What the host does |
|---|---|---|
| Host display: *Duplicate the PC's display* | `virtualDisplay=0` | Streams the physical monitor (stock Sunshine behaviour). |
| Host display: *Separate virtual display* | `virtualDisplay=1&virtualDisplayMode=WxHxFPS` | Creates a virtual display at exactly the streamed resolution and refresh rate, next to the PC's own monitor. |
| Host display: *Virtual display only* | `virtualDisplay=2&virtualDisplayMode=WxHxFPS` | Same, but turns the PC's own monitor off for the session. |
| Virtual display UI scale | `UIscale=150` | Windows text/UI scaling on the virtual display. |
| Close the game after disconnecting | `timeToTerminateApp=300` | Countdown (seconds) before the host closes the game after the stream drops. `-1` never, `0` immediately. Desktop is always closed immediately. |
| Device name shown in Razer Cortex | `devicenickname=...` | Name Razer Cortex shows while waiting for your PIN and in its session list. Also sent on the first `/pair` request. |

The virtual display mode is derived from the resolution and FPS you pick in
Moonlight's normal *Basic Settings*, so the host's virtual display always matches
the stream and nothing gets letterboxed or rescaled.

All of these parameters are ignored by plain Sunshine and GeForce Experience, so
the patched client still works with any other host.

Everything else is upstream moonlight-qt: hardware decoding through VA-API on the
Legion Go S's AMD GPU, gamepad passthrough through SDL, HDR, 120 Hz, touch, and
mDNS discovery of the host on the local network.

Razer ID pairing (the `razer_uuid` / `razer_pincode` flow in `src/nvhttp.cpp`) is
**not** implemented. It needs a Razer account token from Razer's Nexus service.
Normal PIN pairing works and is what the host falls back to.

## Install on the Legion Go S (one command)

Switch to Desktop Mode, open Konsole, and run:

```
curl -fsSL https://raw.githubusercontent.com/mavingaw/Cortex-PC-Remote-Play-Host/main/client-linux/install.sh | bash
```

That downloads the prebuilt AppImage from `dist/` to `~/Applications`, verifies its
checksum, installs an icon and a desktop entry, and adds **Razer PC Remote Play**
to Steam as a non-Steam game with grid, hero and logo artwork from `steam-art/`.
Switch back to Game Mode and it is in your library under **Non-Steam**, looking
like any other game, ready to launch from Big Picture.

On systems without `libfuse2` (AppImages need it to mount themselves) the
installer unpacks the AppImage once and launches the unpacked copy instead.

On a first install the client's settings are seeded with the handheld defaults
from the section below (native 1920x1200 at 60 fps, virtual display only, 150%
UI scale, five minute auto-close) and the device name is taken from the
machine's hardware name, so the first stream needs no setup beyond pairing.
Existing settings are never touched. `RPR_NO_DEFAULTS=1` skips this.

If Steam is running the shortcut is added live. If Steam is closed the script
writes it into `shortcuts.vdf` directly and it appears the next time Steam starts.
Running the script again updates the AppImage and leaves the shortcut alone.

Works the same on Bazzite and on any x86_64 Linux desktop with Steam. Set
`RPR_NO_STEAM=1` to skip the Steam shortcut, `RPR_UNINSTALL=1` to remove the files.

The AppImage takes `libva` from the system so that it uses the system's AMD
VA-API driver for hardware decoding; everything else is bundled.

## Zero-build option

If you only want to stream and do not care about the virtual display or auto-close
options, the stock Moonlight Flatpak already works with this host:

```
flatpak install flathub com.moonlight_stream.Moonlight
```

Pair with a PIN, pick the desktop or a game, and go. The host streams your physical
monitor. Come back here when you want the virtual display.

## Building it yourself

SteamOS and Bazzite have read-only system partitions, so build inside a container.
Both ship `distrobox`. From Desktop Mode, open Konsole:

```
distrobox create --name rp-build --image ubuntu:24.04
distrobox enter rp-build

git clone https://github.com/mavingaw/Cortex-PC-Remote-Play-Host.git
cd Cortex-PC-Remote-Play-Host/client-linux
./scripts/install-deps.sh
./build.sh --appimage
exit
```

That leaves `out/RazerPCRemotePlay-x86_64.AppImage`. To publish it, copy it to
`dist/` and refresh `dist/SHA256SUMS`:

```
cp out/RazerPCRemotePlay-x86_64.AppImage dist/
(cd dist && sha256sum RazerPCRemotePlay-x86_64.AppImage > SHA256SUMS)
```

The Steam artwork is generated from the icon with `python3 scripts/make-steam-art.py`
(needs Pillow).

`./build.sh` without `--appimage` produces `out/moonlight`, which runs directly on
any distro that has the runtime libraries installed. `./scripts/install-deps.sh`
supports apt, dnf and pacman; only the apt list has been exercised end to end.

## Setting up the host (Windows PC)

1. Install Razer Cortex and, inside it, Razer PC Remote Play Host, then
   **Remote Play > Run as Host > Start Hosting**. Or run a build of this
   repository, as the main README describes.
2. The host needs the Razer virtual display driver for the virtual display modes.
   Razer Cortex installs it. Without it the host logs "Not found the virtual
   display" and you should use *Duplicate the PC's display*.
3. On the Legion Go S, launch the client. The host appears automatically if both
   are on the same network (mDNS). Otherwise add it by IP.
4. Select the host and enter the PIN Razer Cortex shows. Cortex displays the
   device name you set in the client's settings.

## Recommended settings for the Legion Go S

In the client's settings page:

- **Resolution**: 1920x1200 (the native panel). Use *Custom* if it is not listed.
- **Frame rate**: 120 if the host GPU keeps up, otherwise 90 or 60.
- **Bitrate**: 20 to 40 Mbps on 5 GHz Wi-Fi, more on Ethernet.
- **Video codec**: HEVC. AV1 if the host GPU encodes it (RTX 40 / RX 7000 or
  newer) and you want lower bitrate at the same quality.
- **Host display**: *Virtual display only* for a handheld session, so the host
  renders at 1920x1200 instead of your monitor's resolution. *Duplicate* if you
  want to see the same picture on the PC.
- **Virtual display UI scale**: 150% for an 8 inch 1920x1200 panel.
- **Close the game after disconnecting**: 5 minutes is a sensible safety net for
  Wi-Fi drops.
- **Video decoder**: leave on *Automatic*. Check the performance overlay
  (Ctrl+Alt+Shift+S during a stream) says VAAPI, not software.

## Working on the patch

```
./build.sh --source-only
cd work/moonlight-qt         # patched upstream checkout
# ... edit ...
git diff > ../../patches/0001-razer-host-support.patch
cd ../.. && ./build.sh
```

To move to a newer upstream, change `UPSTREAM_COMMIT` in `build.sh`, delete
`work/`, run `./build.sh --source-only` and fix any rejected hunks.

Files touched by the patch, all under `app/` in moonlight-qt:

- `settings/streamingpreferences.{h,cpp}`: four new persisted preferences.
- `gui/SettingsView.qml`: the new settings group.
- `backend/nvhttp.{h,cpp}`: `startApp()` takes extra query parameters.
- `streaming/session.cpp`: builds the Razer parameters from the preferences and
  the stream configuration.
- `backend/nvpairingmanager.cpp`: sends `devicenickname` on the first pair request.

## License

moonlight-qt and this patch are GPL-3.0, like the host.
