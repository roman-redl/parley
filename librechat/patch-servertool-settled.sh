#!/bin/sh
# Stops a reply from being written twice when the last model response of the run used code
# execution.
#
# With web_search_20260209 and later (patch-websearch.sh) the model calls code_execution (dynamic
# filtering of the search results), a server tool: its id starts with "srvtoolu_", the provider
# runs it inside the same response, and the code_execution_tool_result block is in the same
# message content (kept there by patch-agents-servertools.sh). The AI message still lists the
# call in tool_calls.
#
# @librechat/agents (dist/{cjs,esm}/tools/ToolNode.*, checked in 4.2.7 and 4.2.15) decides after
# every model call with toolsCondition: it goes to the tool node unless
# areToolCallsInvoked(message, invokedToolIds) is true, that is unless every id in tool_calls is
# in invokedToolIds. invokedToolIds gets only the ids of server web_search calls that returned
# results (handleAnthropicSearchResults, on a web_search_tool_result with a non-empty list of
# web_search_result); a code_execution call is never added, nor is a search that failed or found
# nothing.
# So when the final model response (the one with the answer text) contains code_execution, the
# graph routes to the tool node, which skips "srvtoolu_" calls and runs nothing, and the model is
# called once more and writes the answer again. The reply holds the answer twice and costs an
# extra full response. Seen live: 14 of 21 replies with code_execution were duplicated, none of
# about 290 replies without it; when a client (MCP) tool call comes after code_execution, the
# final response has no code_execution and there is no duplicate.
#
# The patch, in the cjs and esm builds, replaces areToolCallsInvoked: besides the ids in
# invokedToolIds, a call counts as invoked when the message content holds a result block for it
# (a block with a tool_use_id that starts with "srvtoolu_" and a type that ends with
# "_tool_result"), because then the provider has already run it. The rest is as before:
#   - a response with stop_reason "pause_turn" (Anthropic stopped a long server tool loop and
#     expects the request to be repeated to continue it) still routes to the tool node and back to
#     the model, even when every server call in it already has its result: @librechat/agents does
#     not handle pause_turn itself, and only this route continues such a turn;
#   - a server call without its result block in the message still routes to the tool node;
#   - every client tool call (a "toolu_" id, an MCP tool) still routes to the tool node;
#   - only fully settled server calls stop counting as pending.
#
# Needed with patch-websearch.sh: without dynamic filtering there is no code_execution call, and
# the web_search calls are marked by the library (except a search that failed or found nothing,
# which this patch also settles). Drop this
# patch after upgrading to a LibreChat whose @librechat/agents treats settled server tool calls as
# invoked (checked: not in 4.2.15). Not reported upstream yet.
#
# The script fails if the expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time. Running it twice fails
# too, because the original text is gone after the first run. The cjs and esm builds hold the
# same text in the replaced function (it has no module syntax or build-specific names).
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
CJS="$DIST/cjs/tools/ToolNode.cjs"
ESM="$DIST/esm/tools/ToolNode.mjs"

fail() {
  echo "patch-servertool-settled: $1" >&2
  exit 1
}

for f in "$CJS" "$ESM"; do
  [ -f "$f" ] || fail "$f not found"
done

# Replace OLD with NEW in a file only if OLD occurs exactly once; then verify the result.
replace_once() {
  file="$1"
  old="$2"
  new="$3"
  what="$4"
  OLD="$old" NEW="$new" node -e '
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
  ' "$file" || fail "$file: $what not found exactly once"

  # Verify: the new text is present exactly once and the old one is gone (or only inside it).
  OLD="$old" NEW="$new" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    const { OLD, NEW } = process.env;
    const src = fs.readFileSync(file, "utf8");
    if (src.split(NEW).length !== 2) process.exit(1);
    // OLD may legitimately stay inside NEW (an insertion): then it must occur as often as in NEW.
    if (src.split(OLD).length !== NEW.split(OLD).length) process.exit(2);
  ' "$file" || fail "$file: $what not replaced as expected after the patch"
}

# Texts are indented with tabs, as in the build output.

OLD_FUNC='function areToolCallsInvoked(message, invokedToolIds) {
	if (!invokedToolIds || invokedToolIds.size === 0) return false;
	return message.tool_calls?.every((toolCall) => toolCall.id != null && invokedToolIds.has(toolCall.id)) ?? false;
}'
NEW_FUNC='// patch-servertool-settled: an Anthropic server tool call whose result block is already in the message was run by the provider
function areToolCallsInvoked(message, invokedToolIds) {
	if ((message.additional_kwargs?.stop_reason ?? message.response_metadata?.stop_reason) === "pause_turn") return false;
	const settled = new Set();
	if (Array.isArray(message.content)) {
		for (const block of message.content) {
			if (block == null || typeof block !== "object") continue;
			const id = block.tool_use_id;
			if (typeof id === "string" && id.startsWith("srvtoolu_") && typeof block.type === "string" && block.type.endsWith("_tool_result")) settled.add(id);
		}
	}
	if ((!invokedToolIds || invokedToolIds.size === 0) && settled.size === 0) return false;
	return message.tool_calls?.every((toolCall) => toolCall.id != null && (invokedToolIds?.has(toolCall.id) === true || settled.has(toolCall.id))) ?? false;
}'

for f in "$CJS" "$ESM"; do
  ! grep -q "patch-servertool-settled" "$f" || fail "$f: already patched"
  replace_once "$f" "$OLD_FUNC" "$NEW_FUNC" "function areToolCallsInvoked"
done

echo "patch-servertool-settled: server tool calls whose result block is in the message count as invoked in $DIST"
