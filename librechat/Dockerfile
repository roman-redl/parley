# LibreChat with the PWA theme colour changed. The LibreChat version is pinned in the FROM tag:
# an upgrade is a deliberate change of this tag (see CLAUDE.md); patch-pwa.sh fails the build if
# the files it patches changed. The base image is multi-architecture (amd64 + arm64).
FROM registry.librechat.ai/librechat-ai/librechat:v0.8.8

# The base image runs as the unprivileged user "node"; patching needs root only for this step.
USER root
COPY patch-pwa.sh /tmp/patch-pwa.sh
RUN set -eu; \
    sh /tmp/patch-pwa.sh /app/client/dist; \
    chown node:node /app/client/dist/manifest.webmanifest /app/client/dist/sw.js; \
    rm /tmp/patch-pwa.sh
USER node
