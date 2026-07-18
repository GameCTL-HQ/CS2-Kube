#!/usr/bin/env bash
# Build-time fetcher for the GameCTL CS2 plugin catalog (see plugins.tsv).
# Runs in the Dockerfile's addons stage AFTER Metamod + CounterStrikeSharp are
# already in $LAYER. Downloads each pinned upstream release and normalizes its
# archive layout into the layer, which the entrypoint rsyncs onto the volume
# install at boot.
#
# Archive shapes handled (the whole upstream zoo, verified 2026-07-18):
#   addons/ at root (± cfg/, maps/…)      -> merged onto layer root
#   csgo/ wrapper                         -> contents merged onto layer root
#   single wrapper dir holding one of ^   -> unwrapped first
#   plugins|shared|configs|gamedata roots -> merged into addons/counterstrikesharp/
#   bare plugin dir (Name/Name.dll)       -> plugins/<dirname>
#   loose DLL at archive root             -> plugins/<manifest name>
# Some "zips" are actually RAR v5 (WhiteList) — bsdtar handles what unzip can't.
set -euo pipefail

LAYER="${LAYER:-/addons-layer}"
CSS="$LAYER/addons/counterstrikesharp"
TSV="${1:-$(dirname "$0")/plugins.tsv}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

MODE_TIER=()

extract() { # archive dest
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *) unzip -q "$1" -d "$2" 2>/dev/null || { rm -rf "$2"; mkdir -p "$2"; bsdtar -xf "$1" -C "$2"; } ;;
  esac
}

place() { # name workdir  -> merge normalized content into the layer
  local name="$1" work="$2" d
  rm -rf "$work/__MACOSX"

  # Unwrap a single top-level wrapper dir that itself holds a known root.
  local tops=("$work"/*)
  if [ ${#tops[@]} -eq 1 ] && [ -d "${tops[0]}" ]; then
    d="${tops[0]}"
    if [ -d "$d/addons" ] || [ -d "$d/csgo" ] || [ -d "$d/plugins" ] || [ -d "$d/shared" ]; then
      work="$d"
    fi
  fi
  [ -d "$work/csgo" ] && work="$work/csgo"

  if [ -d "$work/addons" ]; then
    local sub
    for sub in addons cfg maps materials models particles scripts sound soundevents; do
      [ -d "$work/$sub" ] || continue
      mkdir -p "$LAYER/$sub"
      cp -a "$work/$sub/." "$LAYER/$sub/"
    done
    return 0
  fi
  if [ -d "$work/plugins" ] || [ -d "$work/shared" ]; then
    local sub
    for sub in plugins shared configs gamedata; do
      [ -d "$work/$sub" ] || continue
      mkdir -p "$CSS/$sub"
      cp -a "$work/$sub/." "$CSS/$sub/"
    done
    return 0
  fi
  if compgen -G "$work/*.dll" >/dev/null; then
    mkdir -p "$CSS/plugins/$name"
    cp -a "$work/." "$CSS/plugins/$name/"
    return 0
  fi
  # bare plugin folder(s): any top-level dir with a DLL at its own top level
  local found=0
  for d in "$work"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    if compgen -G "$d/*.dll" >/dev/null; then
      mkdir -p "$CSS/plugins"
      cp -a "$d" "$CSS/plugins/"
      found=1
    fi
  done
  [ "$found" = 1 ] && return 0
  echo "ERROR: $name — unrecognized archive layout:" >&2
  find "$work" -maxdepth 2 | head -20 >&2
  return 1
}

while IFS=$'\t' read -r name tier url; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  echo "==> $name  ($tier)"
  work="$tmp/$name"; mkdir -p "$work"
  archive="$tmp/$(basename "$url")"
  curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$archive"
  extract "$archive" "$work"
  rm -f "$archive"
  place "$name" "$work"
  rm -rf "$work"
  [ "$tier" = "mode" ] && MODE_TIER+=("$name")
done < "$TSV"

# On-demand metamod plugins: strip their auto-load VDFs — the cfg tree
# `meta load`s them per-mode instead (kus semantics; see plugins.tsv header).
for vdf in multiaddonmanager MovementUnlocker cs2fixes-rampbugfix; do
  rm -f "$LAYER/addons/metamod/$vdf.vdf"
done

# Mode-tier plugins live in plugins/disabled/ — the mode cfgs load them by
# that path (css_plugins load "plugins/disabled/<Name>/<Name>.dll").
mkdir -p "$CSS/plugins/disabled"
for name in "${MODE_TIER[@]}"; do
  [ -d "$CSS/plugins/$name" ] || { echo "ERROR: mode plugin $name did not land in plugins/ (archive dir name mismatch?)" >&2; exit 1; }
  rm -rf "$CSS/plugins/disabled/$name"
  mv "$CSS/plugins/$name" "$CSS/plugins/disabled/$name"
done

# Sanity: the load-bearing pieces the migration gate needs.
for f in \
  "$LAYER/addons/metamod/counterstrikesharp.vdf" \
  "$CSS/plugins/GameModeManager/GameModeManager.dll" \
  "$CSS/plugins/disabled/SharpTimer/SharpTimer.dll" \
  "$CSS/plugins/disabled/MatchZy/MatchZy.dll" \
  "$CSS/plugins/disabled/Deathmatch/Deathmatch.dll" \
  "$CSS/plugins/disabled/RetakesPlugin/RetakesPlugin.dll" \
  "$LAYER/addons/MovementUnlocker/bin/linuxsteamrt64/MovementUnlocker.so" \
  "$LAYER/addons/cs2fixes-rampbugfix/bin/linuxsteamrt64/cs2fixes-rampbugfix.so"; do
  [ -e "$f" ] || { echo "ERROR: sanity check failed — missing $f" >&2; exit 1; }
done

echo "catalog OK: $(find "$CSS/plugins" -maxdepth 1 -mindepth 1 -type d ! -name disabled | wc -l) core, $(find "$CSS/plugins/disabled" -maxdepth 1 -mindepth 1 -type d | wc -l) mode plugins"
