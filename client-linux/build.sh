#!/usr/bin/env bash
#
# Builds the Razer PC Remote Play Linux client: upstream moonlight-qt at a
# pinned commit plus the patches in ./patches.
#
#   ./build.sh                 build ./work/moonlight-qt, binary in ./out/moonlight
#   ./build.sh --appimage      also produce ./out/RazerPCRemotePlay-<arch>.AppImage
#   ./build.sh --source-only   fetch + patch only (to hack on the sources)
#   ./build.sh --jobs N        parallel jobs (default: nproc)
#
# Run ./scripts/install-deps.sh first, or see README.md for the package list.

set -euo pipefail

UPSTREAM_REPO="https://github.com/moonlight-stream/moonlight-qt.git"
UPSTREAM_COMMIT="b0af84ead19e711a55db46f8900182d2e0fa3716"   # moonlight-qt master, 2026-10-14 (v6.2.0 dev)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/work"
SRC="$WORK/moonlight-qt"
BUILD="$WORK/build"
OUT="$HERE/out"
JOBS="$(nproc)"
APPIMAGE=0
SOURCE_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --appimage) APPIMAGE=1 ;;
    --source-only) SOURCE_ONLY=1 ;;
    --jobs) JOBS="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

command -v git >/dev/null || fail "git is required"
command -v qmake6 >/dev/null || fail "qmake6 not found. Run ./scripts/install-deps.sh"

# --------------------------------------------------------------------------- fetch
if [ ! -d "$SRC/.git" ]; then
  log "Fetching moonlight-qt @ $UPSTREAM_COMMIT"
  mkdir -p "$WORK"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM_REPO"
  git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
  git -C "$SRC" submodule update --init --recursive --depth 1
else
  log "Reusing existing checkout in $SRC"
  if [ "$(git -C "$SRC" rev-parse HEAD)" != "$UPSTREAM_COMMIT" ]; then
    fail "$SRC is not at $UPSTREAM_COMMIT. Delete ./work to re-fetch."
  fi
fi

# --------------------------------------------------------------------------- patch
if [ -f "$SRC/.razer-patched" ]; then
  log "Patches already applied"
else
  log "Applying patches"
  for p in "$HERE"/patches/*.patch; do
    echo "  $(basename "$p")"
    git -C "$SRC" apply --check "$p"
    git -C "$SRC" apply "$p"
  done
  touch "$SRC/.razer-patched"
fi

if [ "$SOURCE_ONLY" = 1 ]; then
  log "Sources ready in $SRC"
  exit 0
fi

# --------------------------------------------------------------------------- build
mkdir -p "$BUILD" "$OUT"
log "Configuring"
QMAKE_ARGS=(CONFIG+=release)
if [ "$APPIMAGE" = 1 ]; then
  # Same choices as upstream's scripts/build-appimage.sh: Wayland support drags an
  # old libwayland-client into the image, and linuxdeploy cannot bundle EGLFS/DRM.
  QMAKE_ARGS+=(CONFIG+=disable-wayland CONFIG+=disable-libdrm PREFIX="$WORK/deploy/usr" DEFINES+=APP_IMAGE)
fi
(cd "$BUILD" && qmake6 "$SRC/moonlight-qt.pro" "${QMAKE_ARGS[@]}")

log "Compiling with $JOBS jobs"
(cd "$BUILD" && make -j"$JOBS")
cp "$BUILD/app/moonlight" "$OUT/moonlight"
log "Built $OUT/moonlight"

# --------------------------------------------------------------------------- appimage
if [ "$APPIMAGE" = 1 ]; then
  ARCH="$(uname -m)"
  TOOLS="$WORK/tools"
  mkdir -p "$TOOLS"
  for tool in linuxdeploy linuxdeploy-plugin-qt; do
    if [ ! -x "$TOOLS/$tool" ]; then
      log "Downloading $tool"
      curl -fsSL -o "$TOOLS/$tool" \
        "https://github.com/linuxdeploy/$tool/releases/download/continuous/$tool-$ARCH.AppImage"
      chmod +x "$TOOLS/$tool"
    fi
  done

  log "Staging install tree"
  rm -rf "$WORK/deploy"
  (cd "$BUILD" && make install >/dev/null)

  log "Creating AppImage"
  export PATH="$TOOLS:$PATH"
  export QMAKE=qmake6
  export QML_SOURCES_PATHS="$SRC/app/gui"
  export APPIMAGE_EXTRACT_AND_RUN=1          # works without FUSE (containers, distrobox)
  export OUTPUT="RazerPCRemotePlay-$ARCH.AppImage"
  export VERSION="$(cat "$SRC/app/version.txt")-razer"
  (cd "$OUT" && linuxdeploy --appdir "$WORK/deploy" --plugin qt \
      --exclude-library='libva.so*' --exclude-library='libva-drm.so*' \
      --exclude-library='libva-wayland.so*' --exclude-library='libva-x11.so*' \
      --output appimage)
  log "Built $OUT/$OUTPUT"
fi
