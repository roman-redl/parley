# LibreChat with the PWA theme colour changed, the Shift-held Archive/Delete buttons in the
# sidebar disabled, message timestamps always visible (also on user messages) and formatted
# as clock time, uploaded images kept at the resolution the models accept and tool images
# kept visible to Anthropic models for the rest of the reply, Gemini function calls kept at
# their position when a turn with server-side search parts is replayed, Anthropic web search
# switched to the dynamic-filtering tool version (web_search_20260318) and the server tool
# blocks that version produces (code_execution_tool_result, caller) kept when a turn is
# replayed, and the code execution container id sent back with the next request of a turn.
# The LibreChat version is pinned in the FROM tag: an upgrade is a deliberate change of this
# tag (see CLAUDE.md); patch-pwa.sh, patch-shift.sh, patch-timestamps.sh, patch-images.sh,
# patch-tool-images-run.sh, patch-gemini-order.sh, patch-websearch.sh,
# patch-agents-servertools.sh and patch-anthropic-container.sh fail the build if the files they
# patch changed. The base image is multi-architecture (amd64 + arm64).
FROM registry.librechat.ai/librechat-ai/librechat:v0.8.9

# The base image runs as the unprivileged user "node"; patching needs root only for this step.
USER root
COPY patch-pwa.sh patch-shift.sh patch-timestamps.sh patch-images.sh patch-tool-images-run.sh patch-gemini-order.sh patch-websearch.sh patch-agents-servertools.sh patch-anthropic-container.sh /tmp/
RUN set -eu; \
    sh /tmp/patch-pwa.sh /app/client/dist; \
    chown node:node /app/client/dist/manifest.webmanifest /app/client/dist/sw.js; \
    sh /tmp/patch-tool-images-run.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-gemini-order.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-agents-servertools.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-anthropic-container.sh /app/node_modules/@librechat/agents/dist; \
    sh /tmp/patch-websearch.sh /app/packages/api/dist/index.cjs; \
    sh /tmp/patch-shift.sh /app/client/dist; \
    sh /tmp/patch-timestamps.sh /app/client/dist; \
    chown node:node /app/client/dist/index.html /app/client/dist/index.html.br /app/client/dist/index.html.gz; \
    sh /tmp/patch-images.sh /app; \
    chown node:node /app/api/server/services/Files/images/resize.js; \
    rm /tmp/patch-pwa.sh /tmp/patch-shift.sh /tmp/patch-timestamps.sh /tmp/patch-images.sh /tmp/patch-tool-images-run.sh /tmp/patch-gemini-order.sh /tmp/patch-websearch.sh /tmp/patch-agents-servertools.sh /tmp/patch-anthropic-container.sh
USER node
