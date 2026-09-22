# OPTIONAL golden image. The normal setup works with Docker Sandboxes' built-in Claude image.
# This image exists only to add a predictable general-purpose dev toolbelt.
FROM docker/sandbox-templates:claude-code-docker

USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git jq ripgrep fd-find shellcheck \
      unzip zip sqlite3 postgresql-client redis-tools python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

USER agent
RUN sudo npm install -g corepack@latest \
 && sudo corepack enable

WORKDIR /home/agent/workspace
