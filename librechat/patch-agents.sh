#!/bin/sh
# Stops @librechat/agents from running Anthropic server-side tool calls locally.
#
# While a response streams, @librechat/agents "seals" a tool call when a later content block
# appears and dispatches it for eager local execution (createEagerToolExecutionPlan in
# dist/{cjs,esm}/stream.*). The filter there skips only excluded tools, not Anthropic
# server-side tool calls (ids "srvtoolu_*", e.g. the built-in web_search). When the model emits
# several web_search calls in one message, all but the last were "executed" locally and
# "Error: Tool web_search not found" was written into the message part.
#
# The patch adds the check that the regular path (tools/ToolNode.cjs) already uses:
# !(call.id?.startsWith("srvtoolu_") ?? false).
#
# The script fails if the expected line is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time (and the patch dropped
# if the upstream fixed it).
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
FILES="$DIST/cjs/stream.cjs $DIST/esm/stream.mjs"

fail() {
  echo "patch-agents: $1" >&2
  exit 1
}

# The line in createEagerToolExecutionPlan and its replacement.
OLD='}) : toolCalls).filter((toolCall) => !isEagerExecutionExcludedTool(toolCall.name, graph, agentContext));'
NEW='}) : toolCalls).filter((toolCall) => !isEagerExecutionExcludedTool(toolCall.name, graph, agentContext) && !(toolCall.id?.startsWith("srvtoolu_") ?? false));'

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
      console.error("expected line found " + (parts.length - 1) + " times, need exactly 1");
      process.exit(1);
    }
    fs.writeFileSync(file, parts.join(NEW));
  ' "$f" || fail "$f: pattern in createEagerToolExecutionPlan not found exactly once"

  # Verify: the new text is present exactly once and the old one is gone.
  [ "$(grep -cF -e "$NEW" "$f")" -eq 1 ] || fail "$f: patched line not present after the patch"
  [ "$(grep -cF -e "$OLD" "$f")" -eq 0 ] || fail "$f: original line still present after the patch"
done

echo "patch-agents: srvtoolu_ calls excluded from eager execution in $DIST"
