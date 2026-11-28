#!/usr/bin/env bash
# Render one frame of a converted map (free textures, environment, stand-in props) under Xvfb.
#
#   heavy -- tools/screenshot.sh <world prefix, without .json> <out.png> [--view=spawn|overview] [--cam=x,y,z --look=x,y,z] [--list=file]
#
# Not --headless: that driver draws nothing and saves a black PNG. Mesa's llvmpipe stands in for a GPU.
# A world outside this repo cannot be routed to the GPU boxes: prefix GPU_OFFLOAD=0 to render here.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v Xvfb >/dev/null || { echo "Xvfb not installed" >&2; exit 3; }
[ $# -ge 2 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
# Absolute but NOT symlink-resolved (realpath -s): a world reached through a symlink (game-fatal-contact /worlds) must load by that
# path, or a bug that only shows through the link cannot be reproduced.
WORLD="$(realpath -m -s "$1")"; OUT="$(realpath -m -s "$2")"; shift 2
mkdir -p "$(dirname "$OUT")"
godot --headless --path . --import >/dev/null 2>&1
LIMIT=150; case "$*" in *--list=*) LIMIT=900 ;; esac
# xvfb-run -a is not safe for simultaneous starts: it looks for a free /tmp/.X<n>-lock, but Xvfb writes that lock only
# once it is up, so parallel runs pick the same number (3 of 4 got :99). Here the start is serialized on a lock that
# is held only until this server's socket exists; a server that dies at start (number taken) moves on to the next
# number. The lock is not held while godot runs.
export LIBGL_ALWAYS_SOFTWARE=1
XLOCK="/tmp/gs-map-xvfb-$(id -u).lock"
XPID=""
XNUM=""
start_display() {
  local n i
  exec 9>"$XLOCK" || return 1
  flock 9
  for n in $(seq 99 140); do
    if [ -e "/tmp/.X$n-lock" ] || [ -S "/tmp/.X11-unix/X$n" ]; then continue; fi
    Xvfb ":$n" -screen 0 1280x720x24 -nolisten tcp 9>&- >/dev/null 2>&1 &
    XPID=$!
    for i in $(seq 1 100); do
      [ -S "/tmp/.X11-unix/X$n" ] && break
      kill -0 "$XPID" 2>/dev/null || break
      sleep 0.1
    done
    if [ -S "/tmp/.X11-unix/X$n" ] && kill -0 "$XPID" 2>/dev/null; then
      XNUM="$n"
      flock -u 9
      exec 9>&-
      return 0
    fi
    wait "$XPID" 2>/dev/null
  done
  flock -u 9
  exec 9>&-
  return 1
}
start_display || { echo "no free X display in :99-:140 (lock $XLOCK)" >&2; exit 3; }
trap 'kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null' EXIT
DISPLAY=":$XNUM" timeout "$LIMIT" godot --path . --resolution 1280x720 --rendering-method gl_compatibility --rendering-driver opengl3 res://examples/bsp_world_shot.tscn -- --world="$WORLD" --out="$OUT" "$@"
exit $?
