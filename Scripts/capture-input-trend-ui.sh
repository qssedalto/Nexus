#!/bin/bash
# Run on a logged-in Mac with Screen Recording access for the terminal.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-/private/tmp/nexus-trend-ui-review}"
mkdir -p "$output"
cd "$repo"
swift build -c debug --product Nexus
binary="$(swift build -c debug --show-bin-path)/Nexus"
window_finder="$repo/Scripts/trend-preview-window.swift"
preview_pid=""
trap 'if [[ -n "$preview_pid" ]]; then kill "$preview_pid" 2>/dev/null || true; fi' EXIT

fixtures=(
  "empty:zh-Hans:light:large:"
  "empty:en:dark:small:"
  "sparse:zh-Hans:light:large:"
  "sparse:en:dark:small:"
  "dense:en:light:large:"
  "dense:zh-Hans:dark:large:"
  "scroll:zh-Hans:light:large:"
  "scroll:en:dark:small:"
  "sparse:en:light:large:filter-hover"
)

for fixture in "${fixtures[@]}"; do
  IFS=: read -r scenario language appearance size interaction <<< "$fixture"
  args=(--nexus-trend-preview "--nexus-preview-scenario=$scenario"
        "--nexus-preview-language=$language")
  [[ "$appearance" == dark ]] && args+=(--nexus-preview-dark)
  [[ "$size" == small ]] && args+=(--nexus-preview-small)
  if [[ "$interaction" == filter-hover ]]; then
    args+=(--nexus-preview-filter --nexus-preview-hover)
  fi
  "$binary" "${args[@]}" > "$output/preview.log" 2>&1 &
  preview_pid=$!
  window_id=""
  for _ in {1..20}; do
    window_id="$(swift "$window_finder" 2>/dev/null || true)"
    [[ -n "$window_id" ]] && break
    sleep 0.25
  done
  if [[ -z "$window_id" ]]; then
    echo "No visible preview window: $fixture" >&2
    exit 1
  fi
  name="$scenario-$language-$appearance-$size"
  [[ -n "$interaction" ]] && name="$name-$interaction"
  screencapture -x -l "$window_id" "$output/$name.png"
  echo "$output/$name.png"
  kill "$preview_pid" 2>/dev/null || true
  wait "$preview_pid" 2>/dev/null || true
  preview_pid=""
done
