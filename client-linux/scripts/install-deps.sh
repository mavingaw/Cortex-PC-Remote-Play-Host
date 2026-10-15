#!/usr/bin/env bash
# Installs the packages needed by ../build.sh on Debian/Ubuntu, Fedora or Arch.
# On SteamOS / Bazzite run this inside a distrobox (see README.md).
set -euo pipefail

if command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    build-essential git curl pkg-config file \
    qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qt6-svg-dev \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
    qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
    libsdl2-dev libsdl2-ttf-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    libopus-dev libssl-dev libva-dev libvdpau-dev libdrm-dev \
    libgl1-mesa-dev libegl1-mesa-dev libpulse-dev libasound2-dev \
    wayland-protocols libwayland-dev libxkbcommon-dev
elif command -v dnf >/dev/null; then
  # ffmpeg-devel comes from RPM Fusion; ffmpeg-free-devel (Fedora) also works but
  # lacks some hardware decoders.
  sudo dnf install -y \
    gcc gcc-c++ make git curl pkgconf-pkg-config file \
    qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtsvg-devel \
    SDL2-devel SDL2_ttf-devel ffmpeg-devel opus-devel openssl-devel \
    libva-devel libvdpau-devel libdrm-devel mesa-libGL-devel mesa-libEGL-devel \
    pulseaudio-libs-devel alsa-lib-devel wayland-devel wayland-protocols-devel libxkbcommon-devel
elif command -v pacman >/dev/null; then
  sudo pacman -S --needed \
    base-devel git curl pkgconf file \
    qt6-base qt6-declarative qt6-svg sdl2 sdl2_ttf ffmpeg opus openssl \
    libva libvdpau libdrm mesa libpulse alsa-lib wayland wayland-protocols libxkbcommon
else
  echo "Unsupported distro: install the packages listed in README.md manually." >&2
  exit 1
fi
