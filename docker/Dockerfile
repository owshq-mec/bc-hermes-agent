# Dockerfile for Hermes Agent (course / local setup)
# Nous Research Hermes Agent official image: nousresearch/hermes-agent:stable
ARG BASE_IMAGE=nousresearch/hermes-agent:stable
FROM ${BASE_IMAGE}

USER root

# ==============================================================================
# Bot Desktop (the "Screen" pane) — headless Xfce over RFB
# ==============================================================================
# The official image ships no X stack, so Hermes' Bot Desktop
# (/opt/hermes/tools/bot_desktop/) reports every binary missing and the
# dashboard shows an Install hint instead of a Start button. That hint cannot be
# followed at runtime: the image has no `sudo` and every service runs under
# `s6-setuidgid hermes` (uid 1000). It has to be baked in here, where RUN is
# already root — hence no `sudo` on the command below.
#
# This list is EXACTLY tools/bot_desktop/runtime.py PACKAGES["apt"], in its
# order. Keep it in sync with that list rather than curating it here: the pane
# gates Start on runtime.py REQUIRED_BINARIES (Xvnc, xfwm4, xfce4-panel,
# xfdesktop, xfsettingsd, dbus-run-session, xauth, xdpyinfo, setxkbmap, xprop),
# and the launcher additionally execs xsetroot/xset (x11-xserver-utils).
#
# Deliberately NOT the `xfce4` metapackage: launcher.sh starts the components
# itself (xfsettingsd -> xfwm4 -> xfdesktop -> xfce4-panel) precisely to avoid
# xfce4-session, the screensaver, light-locker, the power manager and the polkit
# agent, which outside a logind session either lock the desktop for a passwordless
# user or pop empty dialogs. The metapackage would drag all of them back in.
#
# fonts-dejavu-core is already present in the base image; it stays listed so the
# set matches runtime.py and survives a base-image change.
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tigervnc-standalone-server \
        xfce4-panel \
        xfwm4 \
        xfdesktop4 \
        xfce4-settings \
        xfce4-terminal \
        dbus-x11 \
        x11-xserver-utils \
        x11-utils \
        x11-xkb-utils \
        xauth \
        fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/*

# Setup default directories for shared files and workdir.
#
# /opt/data/installs MUST exist here with permissive ownership. docker-compose
# mounts a named volume there, and Docker seeds a new named volume from the
# image's mountpoint -- including its owner and mode. If the directory does not
# exist in the image, Docker creates the mountpoint root:root 0755, the Hermes
# worker (uid 1000 "hermes") cannot write to it, and plugin installs fail with
# "Permission denied: /opt/data/installs/<id>".
RUN mkdir -p /opt/data/installs /workspace && \
    chmod -R 777 /opt/data /workspace && \
    chown -R 1000:1000 /opt/data/installs

WORKDIR /opt/data

# ==============================================================================
# Why the Hindsight plugin is NOT installed here
# ==============================================================================
# `hermes plugins install hindsight` writes to $HERMES_HOME/plugins, and
# HERMES_HOME is /opt/data -- which docker-compose.yml bind-mounts over from the
# host (./data). Anything this Dockerfile writes under /opt/data is therefore
# SHADOWED at runtime and invisible to the agent. Baking the install in would
# produce an image that looks right and behaves as if the plugin were missing.
#
# Instead the plugin is installed once at runtime (`make hindsight-install`,
# pinned to an immutable commit SHA) and persists in ./data/plugins on the host,
# so it survives `docker compose down`, `up`, `--force-recreate` and image
# rebuilds. Only `make destroy` removes it.
#
# One caveat that bind mount creates, handled in docker-compose.yml: plugin
# Python dependency environments are built under /opt/data/installs, and Hermes
# copies a Python toolchain containing both share/terminfo/a and
# share/terminfo/A into them. The macOS bind mount is case-INSENSITIVE, so those
# collide and the dependency build fails. docker-compose.yml mounts a named
# volume at /opt/data/installs to give that path a case-sensitive filesystem.
# ==============================================================================

# ==============================================================================
# groups.log wire-contract patch (upstream bug)
# ==============================================================================
# gateway/hosted_rooms.py attaches the optional actor fields in
# _OPTIONAL_ACTOR_FIELDS (display_name, profile, connection_id) to member and
# connection actors, but tui_gateway/contracts/groups_bot_relay.py declares
# RoomActor with kind/id only, and its Result base sets extra="forbid". Every
# groups.log result that carries a profile-backed bot member therefore fails its
# own contract and the gateway logs, ~3x/second while a Groups panel is open:
#
#   ERROR tui_gateway.contracts.registry: result of 'groups.log' violates its
#   wire contract: events.1.actor.profile Extra inputs are not permitted
#
# Validation is observational (registry.check_result only logs unless
# HERMES_TEST_ISOLATION is set) and the result dict is never re-serialised
# through the model, so this is pure log noise -- rooms, bot turns and the room
# log all work. Declaring the three fields the producer already sends silences it
# without changing a byte on the wire.
#
# Patched in the IMAGE, not under /opt/data: the supervised gateway imports
# /opt/hermes (its launcher exports PYTHONPATH=/opt/hermes:<venv site-packages>),
# so the copy under /opt/data/installs/*/workspace is not what runs.
#
# The RUN fails if the anchor text is gone, so a base-image update that fixes or
# reshapes RoomActor surfaces here instead of silently skipping. Drop this block
# once upstream ships the fix.
RUN python3 - <<'PATCH'
import pathlib
p = pathlib.Path("/opt/hermes/tui_gateway/contracts/groups_bot_relay.py")
src = p.read_text()
old = "class RoomActor(Result):\n    kind: str\n    id: str\n"
new = ("class RoomActor(Result):\n"
       "    kind: str\n"
       "    id: str\n"
       "    # gateway/hosted_rooms.py::_OPTIONAL_ACTOR_FIELDS attaches these on member and\n"
       "    # connection actors; Result forbids extras, so they must be declared here.\n"
       "    display_name: str | None = None\n"
       "    profile: str | None = None\n"
       "    connection_id: str | None = None\n")
if new in src:
    print("RoomActor already declares the optional actor fields; nothing to patch")
    raise SystemExit(0)
if src.count(old) != 1:
    raise SystemExit(f"RoomActor anchor not found exactly once ({src.count(old)}) -- "
                     "re-check the upstream contract before rebuilding")
p.write_text(src.replace(old, new))
print("patched RoomActor")
PATCH

# Preserve the official entrypoint and default to gateway run if started as a service
CMD ["gateway", "run"]
