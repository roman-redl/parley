# LibreChat with the PWA theme colour changed, Anthropic server tool calls kept out of local
# tool execution, the Shift-held Archive/Delete buttons in the sidebar disabled, uploaded
# images kept at the resolution the models accept, Gemini 4 models allowed to receive images
# and tool results with images marked in their text, tool images kept visible to the model
# when hook messages follow the tool results. The LibreChat version is pinned in the FROM
# tag: an upgrade is a deliberate change of this tag (see CLAUDE.md); patch-pwa.sh,
# patch-agents.sh, patch-shift.sh, patch-images.sh, patch-gemini-vision.sh,
# patch-tool-images-note.sh and patch-hook-tail-images.sh fail the build if the files they
# patch changed. The base image is multi-architecture (amd64 + arm64).
FROM registry.librechat.ai/librechat-ai/librechat:v0.8.8

# The base image runs as the unprivileged user "node"; patching needs root only for this step.
USER root
COPY patch-pwa.sh patch-agents.sh patch-shift.sh patch-images.sh patch-gemini-vision.sh patch-tool-images-note.sh patch-hook-tail-images.sh /tmp/
RUN set -eu; \
    sh /tmp/patch-pwa.sh /app/client/dist; \
    chown node:node /app/client/dist/manifest.webmanifest /app/client/dist/sw.js; \
    sh /tmp/patch-agents.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-gemini-vision.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-hook-tail-images.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-tool-images-note.sh /app/packages/api/dist; \
    sh /tmp/patch-shift.sh /app/client/dist; \
    chown node:node /app/client/dist/index.html /app/client/dist/index.html.br /app/client/dist/index.html.gz; \
    sh /tmp/patch-images.sh /app; \
    chown node:node /app/api/server/services/Files/images/resize.js; \
    rm /tmp/patch-pwa.sh /tmp/patch-agents.sh /tmp/patch-shift.sh /tmp/patch-images.sh /tmp/patch-gemini-vision.sh /tmp/patch-tool-images-note.sh /tmp/patch-hook-tail-images.sh
USER node
