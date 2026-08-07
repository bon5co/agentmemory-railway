# agentmemory on Railway — one service, prebuilt.
#
# Derived from upstream's own deploy/railway/Dockerfile (rohitg00/agentmemory),
# with three Railway-specific changes:
#
#   1. The image is prebuilt and published, so a deploy pulls a pinned layer
#      instead of running `npm install` on the deployer's build minutes.
#   2. An nginx gateway listens on Railway's injected $PORT and fronts BOTH the
#      REST/MCP API (3111, bearer-gated by the app) and the real-time viewer
#      (3113, gated here with basic auth) — the viewer is an open relay to the
#      API whenever it is loopback-bound, so it must never be published raw.
#   3. The HMAC secret comes from the environment (${{secret(32)}} in the
#      template) instead of being generated into the deploy log on first boot.
#
# iii-sdk is pinned to the engine version through the local prefix's
# `overrides` field. `npm install -g` IGNORES overrides, so a global install of
# agentmemory resolves its `iii-sdk: ^0.11.2` range up to 0.11.6 — the release
# that switched to the sandboxed worker model agentmemory is not refactored for
# — and the pairing fails as EPIPE reconnect loops and empty search after save.
ARG III_VERSION=0.11.2

FROM iiidev/iii:${III_VERSION} AS iii-image

FROM node:22-slim

ARG AGENTMEMORY_VERSION=0.9.28
ARG III_VERSION=0.11.2
ARG III_SDK_VERSION=0.11.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssl ca-certificates tini gosu curl nginx \
 && rm -rf /var/lib/apt/lists/*

COPY --from=iii-image /app/iii /usr/local/bin/iii

WORKDIR /opt/agentmemory
RUN printf '{"name":"agentmemory-railway","version":"1.0.0","private":true,"overrides":{"iii-sdk":"%s"}}\n' "${III_SDK_VERSION}" > package.json \
 && npm install "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" --omit=optional --no-fund --no-audit \
 && ln -s /opt/agentmemory/node_modules/.bin/agentmemory /usr/local/bin/agentmemory

# Fail the build rather than the deploy if the engine/SDK pairing ever drifts.
RUN test "$(node -p "require('/opt/agentmemory/node_modules/iii-sdk/package.json').version")" = "${III_SDK_VERSION}" \
 && test "$(node -p "require('/opt/agentmemory/node_modules/@agentmemory/agentmemory/package.json').version")" = "${AGENTMEMORY_VERSION}"

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    AGENTMEMORY_VERSION=${AGENTMEMORY_VERSION} \
    TINI_SUBREAPER=1 \
    NODE_ENV=production

COPY --chmod=0755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint.sh"]
