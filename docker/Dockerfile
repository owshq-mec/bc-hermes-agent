# Dockerfile for Hermes Agent (course / local setup)
# Nous Research Hermes Agent official image: nousresearch/hermes-agent:stable
ARG BASE_IMAGE=nousresearch/hermes-agent:stable
FROM ${BASE_IMAGE}

USER root

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

# Preserve the official entrypoint and default to gateway run if started as a service
CMD ["gateway", "run"]
