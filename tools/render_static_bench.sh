#!/usr/bin/env bash
# What a converted map's static world costs the renderer from a fixed camera path (tools/static_render_bench.gd prints STATIC_BENCH rows).
#
#   gpu.sh shot --stage <pack dir> gs-map tools/render_static_bench.sh --world=<prefix> [--runs=3] [--spawns=8] [--splits=4] [--opt.batch_props=true] [--shot=<dir>, with gpu.sh --pull <dir>]
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a -s "-screen 0 1280x720x24" "${GODOT:-godot}" --path . --resolution 1152x650 \
    res://tools/static_render_bench.tscn -- "$@"
