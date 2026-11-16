#!/bin/sh
# Switches Anthropic's built-in web search tool from web_search_20250305 to web_search_20260209.
#
# LibreChat hardcodes the tool definition { type: "web_search_20250305", name: "web_search" }
# in packages/api/src/endpoints/anthropic/llm.ts (built into packages/api/dist/index.cjs, the
# only built copy the server loads). The 20260209 version adds dynamic filtering: Claude filters
# the search results with code execution before they enter the context, which cuts input tokens
# several times on questions with many searches. No other tool parameter is needed: the API
# provisions code execution itself and "allowed_callers" defaults to it. No beta header is needed.
#
# The rest of the image does not compare against the exact type string: LibreChat
# (isProviderWebSearchTool) and @librechat/agents (anthropicToolCache) match the "web_search"
# prefix. The only other occurrence is a doc comment in the same file, which is left as is.
#
# The script fails if the expected text is not found exactly once: a LibreChat upgrade that
# changes this code must be noticed at build time (and the patch dropped once LibreChat makes
# the tool version configurable or uses the newer version itself).
set -eu

FILE="${1:-/app/packages/api/dist/index.cjs}"

fail() {
  echo "patch-websearch: $1" >&2
  exit 1
}

# The property of the tool definition (double quotes: the doc comment uses single quotes).
OLD='type: "web_search_20250305",'
NEW='type: "web_search_20260209",'

[ -f "$FILE" ] || fail "$FILE not found"

# Replace only if OLD occurs exactly once in the file.
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
' "$FILE" || fail "$FILE: web search tool type not found exactly once"

# Verify: the new text is present exactly once and the old one is gone.
[ "$(grep -cF -e "$NEW" "$FILE")" -eq 1 ] || fail "$FILE: patched tool type not present after the patch"
[ "$(grep -cF -e "$OLD" "$FILE")" -eq 0 ] || fail "$FILE: original tool type still present after the patch"

echo "patch-websearch: web search tool type web_search_20260209 in $FILE"
