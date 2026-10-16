#!/usr/bin/env bash
#
# Protocol test for the Linux client against a stand-in for Razer PC Remote Play Host.
#
# tests/fake_host.py implements the host's pairing handshake exactly as src/nvhttp.cpp
# and src/crypto.cpp do, plus /serverinfo, /applist and /launch. This script pairs the
# client with it using the CLI, launches Desktop and a game, and checks that the
# requests carry the Razer parameters the patch adds.
#
#   tests/run-protocol-test.sh [path to moonlight binary, AppRun or AppImage]
#
# Defaults to ./out/moonlight. Needs python3 with the 'cryptography' module, curl, and
# Xvfb when there is no display. Nothing is streamed: the fake host points the
# client at a closed RTSP port, so each launch fails right after the request we check.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="${1:-$HERE/../out/moonlight}"
[ -x "$CLIENT" ] || { echo "client binary not found: $CLIENT" >&2; exit 2; }
python3 -c 'import cryptography' 2>/dev/null || { echo "python3 'cryptography' module is required" >&2; exit 2; }

WORK="$(mktemp -d)"
PIN=4321
export HOME="$WORK/home"
mkdir -p "$HOME/.config/Moonlight Game Streaming Project"
cat > "$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf" <<CONF
[General]
width=1920
height=1200
fps=60
razerdisplaymode=2
razeruiscale=150
razerautoclose=300
razernickname=Test Handheld
CONF

# One virtual display for the whole run, so the timeouts below hit the client itself
# rather than an xvfb-run wrapper (which would leave the client running).
XVFB=""
if [ -z "${DISPLAY:-}" ]; then
  command -v Xvfb >/dev/null || { echo "no DISPLAY and Xvfb is not installed" >&2; exit 2; }
  Xvfb :99 -screen 0 1920x1200x24 > /dev/null 2>&1 &
  XVFB=$!
  export DISPLAY=:99
  sleep 1
fi

python3 "$HERE/fake_host.py" "$WORK" "$PIN" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; [ -n "$XVFB" ] && kill $XVFB 2>/dev/null || true; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do curl -s -m 1 http://127.0.0.1:47989/serverinfo >/dev/null 2>&1 && break; sleep 0.2; done
curl -s -m 1 http://127.0.0.1:47989/serverinfo >/dev/null || { echo "fake host did not start"; cat "$WORK/server.log"; exit 1; }

# The CLI does not always exit on its own under a virtual display, and may ignore SIGTERM;
# each step is bounded by a timeout that escalates to SIGKILL.
timeout -k 5 25 "$CLIENT" pair 127.0.0.1 --pin "$PIN" > "$WORK/pair.log" 2>&1 || true
timeout -k 5 25 "$CLIENT" stream 127.0.0.1 Desktop > "$WORK/stream-desktop.log" 2>&1 || true
timeout -k 5 25 "$CLIENT" stream 127.0.0.1 "Test Game" > "$WORK/stream-game.log" 2>&1 || true

python3 - "$WORK/requests.jsonl" <<'PY'
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
pair = [r["args"] for r in reqs if r["path"] == "/pair"]
launches = [r["args"] for r in reqs if r["path"] in ("/launch", "/resume")]
fails = []
def expect(cond, msg):
    if not cond: fails.append(msg)

stages = [a.get("phrase") or next((k for k in ("clientchallenge", "serverchallengeresp", "clientpairingsecret") if k in a), "?") for a in pair]
expect(stages == ["getservercert", "clientchallenge", "serverchallengeresp", "clientpairingsecret", "pairchallenge"],
       f"pairing stages: {stages}")
expect(pair and pair[0].get("devicenickname") == "Test Handheld", "devicenickname missing on first pair request")
expect(any(r["https"] and r["path"] == "/pair" for r in reqs), "pairchallenge was not sent over HTTPS")

expect(len(launches) == 2, f"expected 2 launch requests, got {len(launches)}")
for a in launches:
    expect(a.get("mode") == "1920x1200x60", f"mode={a.get('mode')}")
    expect(a.get("virtualDisplay") == "2", f"virtualDisplay={a.get('virtualDisplay')}")
    expect(a.get("virtualDisplayMode") == "1920x1200x60", f"virtualDisplayMode={a.get('virtualDisplayMode')}")
    expect(a.get("UIscale") == "150", f"UIscale={a.get('UIscale')}")
    expect(a.get("devicenickname") == "Test Handheld", f"devicenickname={a.get('devicenickname')}")
by_app = {a.get("appid"): a for a in launches}
expect(by_app.get("1", {}).get("timeToTerminateApp") == "0", "Desktop should send timeToTerminateApp=0")
expect(by_app.get("2", {}).get("timeToTerminateApp") == "300", "game should send timeToTerminateApp=300")

for r in reqs:
    tag = r["args"].get("phrase") or ("appid=" + r["args"]["appid"] if "appid" in r["args"] else "")
    print(f"  {'HTTPS' if r['https'] else 'HTTP '} {r['path']} {tag}")
if fails:
    print("FAIL"); [print(" -", f) for f in fails]; sys.exit(1)
print("PASS: pairing handshake and Razer launch parameters verified")
PY
