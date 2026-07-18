# overlay/ — vendored mode configuration tree

`csgo/` is the game-mode cfg tree (cfg/*, gamemodes_server.txt, mapcycle.txt,
subscribed_*.txt) vendored from [kus/cs2-modded-server](https://github.com/kus/cs2-modded-server)
at commit `8c8f89b1fbdb50033430c0eb5a5257a6d8c813af` (2026-06-27), MIT-licensed
(see `KUS-LICENSE`). **Configs only — no plugin binaries are copied from kus.**
Every plugin DLL in this image is fetched from that plugin's own upstream
release (see `catalog/plugins.tsv`).

This tree is what GameCTL's mode catalog (RTV modes, GameModeManager mode
switch, the `custom_*.cfg` overlay hooks) execs at runtime, so it must keep
kus's file names and `plugins/disabled/` load paths. Local changes on top of
it belong in GameCTL's generator overlays, not here — keep this tree a clean
vendor drop so it can be re-synced against upstream.
