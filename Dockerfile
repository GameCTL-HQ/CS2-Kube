# GameCTL Counter-Strike 2 dedicated server image — built from scratch so
# GameCTL controls exactly what runs. STATUS: foundation — vanilla + Metamod +
# CounterStrikeSharp work; the full mode/plugin catalog (GameModeManager,
# SharpTimer, MatchZy, ...) lands next (see README).
#
# Sources: Debian's official base, Valve's official steamcmd, Metamod:Source
# from metamodsource.net, CounterStrikeSharp from its GitHub releases. The
# game (~35GB, app 730, needs GSLT to be public) installs to the persistent
# volume at /home/steam/cs2 on first boot; a normal boot NEVER runs steamcmd.
# GAMECTL_VALIDATE=1 (GameCTL's auto-update toggle) forces a validate/update
# rollout — including the appmanifest reset that clears the 0x6 wedge.
FROM debian:12-slim AS addons

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq unzip tar \
    && rm -rf /var/lib/apt/lists/*

# Metamod:Source (latest 2.0 dev build — the CS2-supported line).
ARG MMS_VERSION=
RUN mkdir -p /addons-layer && cd /tmp \
    && mm="${MMS_VERSION:-$(curl -fsSL https://mms.alliedmods.net/mmsdrop/2.0/mmsource-latest-linux)}" \
    && curl -fsSL "https://mms.alliedmods.net/mmsdrop/2.0/${mm}" -o mms.tar.gz \
    && tar -xzf mms.tar.gz -C /addons-layer \
    && rm mms.tar.gz

# CounterStrikeSharp (with runtime) from its own GitHub releases.
ARG CSS_VERSION=latest
RUN cd /tmp \
    && if [ "$CSS_VERSION" = "latest" ]; then \
         url="$(curl -fsSL https://api.github.com/repos/roflmuffin/CounterStrikeSharp/releases/latest \
               | jq -r '.assets[] | select(.name | test("with-runtime-linux")) | .browser_download_url' | head -1)"; \
       else \
         url="$(curl -fsSL "https://api.github.com/repos/roflmuffin/CounterStrikeSharp/releases/tags/${CSS_VERSION}" \
               | jq -r '.assets[] | select(.name | test("with-runtime-linux")) | .browser_download_url' | head -1)"; \
       fi \
    && curl -fsSL "$url" -o css.zip \
    && unzip -q css.zip -d /addons-layer \
    && rm css.zip \
    && ls /addons-layer/addons/counterstrikesharp >/dev/null


FROM debian:12-slim

RUN dpkg --add-architecture i386 && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl lib32gcc-s1 libnss-wrapper coreutils tini util-linux rsync \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd && cd /opt/steamcmd \
    && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar xz \
    && /opt/steamcmd/steamcmd.sh +quit \
    && useradd -u 1000 -d /home/steam -m -s /bin/bash steam

# The addons layer (metamod + CSS) is baked in the image and rsync'd onto the
# volume install each boot — game updates can't wipe the mods.
COPY --from=addons /addons-layer /opt/addons-layer
COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENV DATA_DIR=/home/steam/cs2 \
    PORT=27015 \
    TICKRATE=128 \
    MAXPLAYERS=24 \
    LAN=0 \
    EXEC=on_boot.cfg \
    CUSTOM_FOLDER=custom_files \
    GAMECTL_VALIDATE=0 \
    UID=1000 \
    GID=1000

EXPOSE 27015/tcp 27015/udp 27020/udp
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
