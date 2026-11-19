# LibreChat with the PWA theme colour changed, Anthropic server tool calls kept out of local
# tool execution and the Shift-held Archive/Delete buttons in the sidebar disabled. The LibreChat
# version is pinned in the FROM tag: an upgrade is a deliberate change of this tag (see
# CLAUDE.md); patch-pwa.sh, patch-agents.sh and patch-shift.sh fail the build if the files they
# patch changed. The base image is multi-architecture (amd64 + arm64).
FROM registry.librechat.ai/librechat-ai/librechat:v0.8.8

# The base image runs as the unprivileged user "node"; patching needs root only for this step.
USER root
COPY patch-pwa.sh patch-agents.sh patch-shift.sh /tmp/
RUN set -eu; \
    sh /tmp/patch-pwa.sh /app/client/dist; \
    chown node:node /app/client/dist/manifest.webmanifest /app/client/dist/sw.js; \
    sh /tmp/patch-agents.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-shift.sh /app/client/dist; \
    chown node:node /app/client/dist/index.html /app/client/dist/index.html.br /app/client/dist/index.html.gz; \
    rm /tmp/patch-pwa.sh /tmp/patch-agents.sh /tmp/patch-shift.sh
USER node
