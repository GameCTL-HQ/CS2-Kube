# CS2-Kube

**Status: planning — image not built yet.** GameCTL currently runs
`ghcr.io/kus/cs2-modded-server`; this repo will replace it with a from-scratch
build. This is the most involved conversion because GameCTL's CS2 integration
(mode switching, RTV, surf, DM) leans on the plugin catalog the kus image
bundles — a from-scratch image must rebuild that catalog from each plugin's
own upstream releases, not copy kus's bundle.

## Design (agreed)

- **Base:** Debian official + Valve's official steamcmd (as in the other
  GameCTL-HQ images). CS2 (~35GB, app 730 + GSLT) installs to the persistent
  volume at pod start (volume-cache pattern; far too large to bake) with the
  cold-start retry loop.
- **Baked addons layer** (versions pinned by ARG, each from its own upstream):
  - Metamod:Source (metamodsource.net dev builds)
  - CounterStrikeSharp (roflmuffin/CounterStrikeSharp releases)
  - The mode/plugin catalog GameCTL's generator references — inventory from
    kus parity, each from its own repo: GameModeManager, MatchZy, SharpTimer
    (+ST-Fixes), K4-Arenas, Deathmatch Core, CS2_GunGame, RetakesPlugin (+
    Allocator, Instadefuse, Executes), PropHunt, Advertisement, WhiteList,
    MutualScoringPlayers, Damage Informations, Remove Map Weapons,
    Open Prefire Prac, Deathrun Manager, CS2_ExecAfter.
  - Entry point applies the addons layer ONTO the volume install each boot
    (overlay copy, version-stamped) so game updates don't wipe mods.
- **GameCTL's own plugins** (GameCtlRtv, GameCtlSurfHUD, GameCtlDmRounds)
  stay overlay-injected by the generator, unchanged.
- **Update watch:** keep GameCTL's cs2-update-watch (the 0x6 wedge handling —
  delete stuck appmanifest_730.acf to force a clean validate).
- **Networking/env contract:** identical to what the generator sends today
  (GSLT, ports, mariadb-backed records untouched).

## Migration safety

The live cs2-modded server (surf timer work pending) is NOT flipped until the
new image passes: vanilla boot → Metamod loads → CSS loads → GameModeManager
mode switch → RTV two-stage vote → surf mode with SharpTimer — on a scratch
volume first, then a copy of the live volume.
