#!/bin/sh
# Makes Gemini 4 and later count as multimodal models in @librechat/agents.
#
# CustomChatGoogleGenerativeAI._isMultimodalModel (dist/{cjs,esm}/llm/google/index.*) decides
# whether image parts may be sent to the model. It lists gemini-1.5, gemini-2, gemma-3 (except
# gemma-3-1b) and gemini-3, so gemini-4-* (hydrogen, argon, carbon, neon) was not recognised:
# any image in the conversation (a user upload, an MCP screenshot artifact) made
# convertBaseMessagesToContent() (llm/google/utils/common.*) throw "This model does not
# support images", and the run ended with "Upstream model error".
#
# The patch replaces the gemini-3 prefix check with the pattern that the upstream now uses for
# "Gemini 3 or later" (isGemini3PlusModel in src/llm/google/utils/common.ts of
# LibreChat-AI/agents, PR #620): gemini-3 to gemini-9 and gemini-10 and above, followed by "."
# or "-" or the end of the name (gemini-3-pro, gemini-3.8-flash, gemini-4-hydrogen).
#
# The script fails if the expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time (and the patch dropped
# if the upstream fixed it). Running it twice fails too, because the original text is gone
# after the first run.
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
FILES="$DIST/cjs/llm/google/index.cjs $DIST/esm/llm/google/index.mjs"

fail() {
  echo "patch-gemini-vision: $1" >&2
  exit 1
}

# The tail of the _isMultimodalModel return expression and its replacement.
OLD='!this.model.startsWith("gemma-3-1b") || this.model.startsWith("gemini-3");'
NEW='!this.model.startsWith("gemma-3-1b") || /^gemini-(?:[3-9]|[1-9]\d+)(?:[.-]|$)/.test(this.model);'

for f in $FILES; do
  [ -f "$f" ] || fail "$f not found"
done

# Replace only if OLD occurs exactly once in the file.
for f in $FILES; do
  OLD="$OLD" NEW="$NEW" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    const { OLD, NEW } = process.env;
    const src = fs.readFileSync(file, "utf8");
    const parts = src.split(OLD);
    if (parts.length !== 2) {
      console.error("expected text found " + (parts.length - 1) + " times, need exactly 1");
      process.exit(1);
    }
    fs.writeFileSync(file, parts.join(NEW));
  ' "$f" || fail "$f: pattern in _isMultimodalModel not found exactly once"

  # Verify: the new text is present exactly once and the old one is gone.
  [ "$(grep -cF -e "$NEW" "$f")" -eq 1 ] || fail "$f: patched line not present after the patch"
  [ "$(grep -cF -e "$OLD" "$f")" -eq 0 ] || fail "$f: original line still present after the patch"
done

echo "patch-gemini-vision: gemini-3 and later accepted as multimodal in $DIST"
