#!/usr/bin/env bash
# GameCTL CS2 entrypoint (foundation). The game lives on the volume at
# $DATA_DIR (/home/steam/cs2 — same mount contract as the kus-based deploys);
# a normal boot never runs steamcmd. GAMECTL_VALIDATE=1 (GameCTL's auto-update
# toggle) runs a validate/update rollout, including the appmanifest reset that
# clears the StateFlags-6 wedge (verified on-cluster 2026-07-12).
#
# Env (kus-compatible names GameCTL already sends): PORT, TICKRATE, MAXPLAYERS,
# STEAM_ACCOUNT (GSLT), API_KEY (Workshop), RCON_PASSWORD, SERVER_PASSWORD,
# LAN, EXEC, CUSTOM_FOLDER, GAMECTL_CS2_MODE (informational here — mode logic
# is driven by the overlay configs GameCTL writes into $CUSTOM_FOLDER).
set -euo pipefail

DATA="${DATA_DIR:-/home/steam/cs2}"
uid="${UID:-1000}"; gid="${GID:-1000}"
port="${PORT:-27015}"

echo "gamectl: entrypoint starting (data: $DATA)"
export HOME=/home/steam
GAMEDIR="$DATA"
CSGO="$GAMEDIR/game/csgo"
mkdir -p "$GAMEDIR" "$DATA/.gamectl/steamhome"
chown "$uid:$gid" "$DATA" "$GAMEDIR" "$DATA/.gamectl" "$DATA/.gamectl/steamhome" 2>/dev/null || true
# One-time migration: installs made by older builds (or the kus image) can be
# root-owned; CS2 (as the run user) writes throughout the tree, so fix
# ownership once. Sentinel = the cs2 binary's owner.
if [ -e "$GAMEDIR/game/bin/linuxsteamrt64/cs2" ] && [ "$(stat -c %u "$GAMEDIR/game/bin/linuxsteamrt64/cs2")" != "$uid" ]; then
  echo "gamectl: one-time ownership migration of the install (may take a few minutes)"
  chown -R "$uid:$gid" "$GAMEDIR" 2>/dev/null || true
fi

# steamcmd runs AS the run user so the entire install is owned by it (CS2
# writes CWD-relative logs, workshop maps, shader caches all over the tree).
as_user() {
  if [ "$(id -u)" = "0" ]; then setpriv --reuid "$uid" --regid "$gid" --clear-groups "$@"; else "$@"; fi
}
steamcmd_update() {
  chown -R "$uid:$gid" "$DATA/.gamectl/steamhome" /opt/steamcmd 2>/dev/null || true
  for i in 1 2 3 4 5 6; do
    as_user env HOME="$DATA/.gamectl/steamhome" /opt/steamcmd/steamcmd.sh \
      +force_install_dir "$GAMEDIR" +login anonymous +app_update 730 "$@" +quit && return 0
    echo "gamectl: steamcmd attempt $i failed — clearing appcache and retrying" >&2
    rm -rf "$DATA/.gamectl/steamhome/Steam/appcache" 2>/dev/null || true
    [ "$i" -ge 4 ] && { echo "gamectl: resetting steam state" >&2; rm -rf "$DATA/.gamectl/steamhome/Steam" 2>/dev/null || true; }
    sleep 10
  done
  return 1
}

need_install=0
[ -x "$GAMEDIR/game/bin/linuxsteamrt64/cs2" ] || need_install=1
if [ "${GAMECTL_VALIDATE:-0}" = "1" ] || [ "$(echo "${UPDATE_ON_START:-false}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
  # Forced update: clear a possible 0x6 wedge first (stuck appmanifest keeps
  # steamcmd re-failing the incremental job and the server stays stale).
  echo "gamectl: forced validate/update requested"
  rm -f "$GAMEDIR/steamapps/appmanifest_730.acf" 2>/dev/null || true
  rm -rf "$GAMEDIR/steamapps/downloading/730" "$GAMEDIR/steamapps/temp/730" 2>/dev/null || true
  steamcmd_update validate || { [ "$need_install" = "0" ] && echo "gamectl: WARN update failed, starting existing install" || { echo "ERROR: install failed" >&2; exit 1; }; }
elif [ "$need_install" = "1" ]; then
  echo "gamectl: installing CS2 into $GAMEDIR (~35GB — first boot only)"
  rm -rf "$GAMEDIR/steamapps/downloading"/* "$GAMEDIR/steamapps/temp"/* 2>/dev/null || true
  steamcmd_update validate || { echo "ERROR: install failed" >&2; exit 1; }
else
  echo "gamectl: existing install found — starting without steamcmd (auto-update toggle to update)"
fi

# --- Addons layer: metamod + CounterStrikeSharp (+ catalog when it lands) ---
# rsync'd onto the install every boot so game updates never wipe the mods;
# --ignore-existing for configs so operator/GameCTL-overlay edits win.
echo "gamectl: applying addons layer (metamod + CounterStrikeSharp)"
rsync -a --chown="$uid:$gid" --exclude 'addons/counterstrikesharp/configs' /opt/addons-layer/ "$CSGO/"
rsync -a --chown="$uid:$gid" --ignore-existing /opt/addons-layer/addons/counterstrikesharp/configs/ "$CSGO/addons/counterstrikesharp/configs/" 2>/dev/null || true
mkdir -p "$CSGO/addons/counterstrikesharp/logs" "$CSGO/addons/metamod/logs"
chown -R "$uid:$gid" "$CSGO/addons/counterstrikesharp/logs" "$CSGO/addons/metamod/logs" 2>/dev/null || true
# Register metamod in gameinfo.gi (idempotent — kus-equivalent step).
GI="$CSGO/gameinfo.gi"
if [ -f "$GI" ] && ! grep -q 'csgo/addons/metamod' "$GI"; then
  sed -i 's|\(\s*\)Game_LowViolence\(.*\)|\1Game_LowViolence\2\n\1Game\tcsgo/addons/metamod|' "$GI"
  grep -q 'csgo/addons/metamod' "$GI" && echo "gamectl: metamod registered in gameinfo.gi" \
    || echo "gamectl: WARN could not register metamod in gameinfo.gi" >&2
fi

# --- GameCTL custom_files overlay (same semantic as kus CUSTOM_FOLDER) ------
OV="/home/${CUSTOM_FOLDER:-custom_files}"
if [ -d "$OV" ] && [ -n "$(ls -A "$OV" 2>/dev/null)" ]; then
  echo "gamectl: applying $OV overlay"
  rsync -a --chown="$uid:$gid" "$OV/" "$CSGO/"
fi

chown "$uid:$gid" "$CSGO" 2>/dev/null || true
chown -R "$uid:$gid" "$CSGO/addons/counterstrikesharp/configs" "$CSGO/cfg" 2>/dev/null || true

# --- Launch -----------------------------------------------------------------
args=(-dedicated -console -usercon
  -port "$port"
  -maxplayers "${MAXPLAYERS:-24}"
  -tickrate "${TICKRATE:-128}"
  +map de_dust2
  +exec "${EXEC:-on_boot.cfg}")
[ -n "${API_KEY:-}" ] && args+=(-authkey "$API_KEY")
[ -n "${STEAM_ACCOUNT:-}" ] && args+=(+sv_setsteamaccount "$STEAM_ACCOUNT")
[ "${LAN:-0}" = "1" ] && args+=(+sv_lan 1)
[ -n "${RCON_PASSWORD:-}" ] && args+=(+rcon_password "$RCON_PASSWORD")
[ -n "${SERVER_PASSWORD:-}" ] && args+=(+sv_password "$SERVER_PASSWORD")
# shellcheck disable=SC2206
[ -n "${EXTRA_ARGS:-}" ] && args+=(${EXTRA_ARGS})

# Steamworks SDK: the gameserver dlopens ~/.steam/sdk64/steamclient.so.
mkdir -p "$HOME/.steam/sdk64"
ln -sf /opt/steamcmd/linux64/steamclient.so "$HOME/.steam/sdk64/steamclient.so"
chown -R "$uid:$gid" "$HOME/.steam" 2>/dev/null || true

echo "gamectl: starting CS2 — port ${port}, tickrate ${TICKRATE:-128}, maxplayers ${MAXPLAYERS:-24}"
cd "$GAMEDIR/game/bin/linuxsteamrt64"
export LD_LIBRARY_PATH="$GAMEDIR/game/bin/linuxsteamrt64:${LD_LIBRARY_PATH:-}"
# stdbuf: CS2's stdio block-buffers to a pipe → logs stall in 64KB chunks
# without it (the kus-era sed patch, now native).
run=(stdbuf -oL -eL ./cs2 "${args[@]}")
if [ "$(id -u)" = "0" ]; then
  exec setpriv --reuid "$uid" --regid "$gid" --clear-groups "${run[@]}"
else
  exec "${run[@]}"
fi
