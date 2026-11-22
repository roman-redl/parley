#!/bin/sh
# Keeps Anthropic server tool blocks intact when @librechat/agents replays a turn: the
# code_execution_tool_result block (and the other server tool result blocks) and the "caller"
# field.
#
# With web_search_20260209 and later (patch-websearch.sh) the model calls code_execution (a server tool,
# "srvtoolu_" id) and the nested web_search calls carry caller { type: "code_execution_20260120",
# tool_id: <id of the code_execution call> }. The assistant message holds server_tool_use
# (code_execution), server_tool_use (web_search, with caller), web_search_tool_result (with
# caller) and code_execution_tool_result, and all of them must be sent back unchanged. When the
# next request continues the same assistant message (for example after a client or MCP tool
# call), @librechat/agents (dist/{cjs,esm}/llm/anthropic/utils/message_{inputs,outputs}.*):
#   - drops the code_execution_tool_result block: the stream parser turns only tool_use,
#     document, server_tool_use and web_search_tool_result block starts into chunks, and the
#     replay rebuilder replaces any "srvtoolu_" result whose content is not a web search result
#     with null (the type is not in its list of tool block types either);
#   - rebuilds server_tool_use and web_search_tool_result with a fixed set of fields, which drops
#     caller;
#   so Anthropic answers 400 "`code_execution` tool use with id `srvtoolu_...` was found without
#   a corresponding `code_execution_tool_result` block". Reported as LibreChat-AI/agents#690.
#
# This is a port of LibreChat-AI/agents PR #720 (open when written) to the compiled 4.2.7 code,
# in four replacements in each build:
#   1. message_outputs, _makeMessageChunkFromAnthropicEvent: a content_block_start of
#      code_execution_tool_result, web_fetch_tool_result, bash_code_execution_tool_result,
#      text_editor_code_execution_tool_result or tool_search_tool_result becomes a chunk, like
#      web_search_tool_result.
#   2. message_inputs, _formatContent: a list serverToolResultTypes of those result types and
#      web_search_tool_result; every one of them is also a known tool block type.
#   3. message_inputs, _formatContent: the rebuilt server_tool_use keeps caller when present.
#   4. message_inputs, _formatContent: a "srvtoolu_" result block of any type in
#      serverToolResultTypes is rebuilt as { type, tool_use_id, content } plus caller (without the
#      stream-only properties index and input); the web_search_tool_result keeps its checks and
#      also keeps caller.
# and one more that PR #720 does not have (found on a live test):
#   5. messages/core, allowedTypesByProvider.anthropic: the server tool result types are allowed
#      block types. After the stream, the graph passes the final Anthropic message through
#      modifyDeltaProperties -> modifyContent, which turns every block of a type missing from this
#      list into an empty "text" block. code_execution_tool_result was missing, so the results
#      never reached the replay, whatever message_inputs does; Anthropic resends a missing result
#      once in the next response, and the request after that failed with the 400 above (seen when a
#      turn takes four or more requests).
#
# Drop this patch after upgrading to a LibreChat whose @librechat/agents includes PR #720 and the
# allowed types fix (LibreChat-AI/agents#690 fixed); it is needed only while patch-websearch.sh
# is in use.
#
# The script fails if an expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time. Running it twice fails
# too, because the original text is gone after the first run. The cjs and esm builds hold the
# same text in the replaced blocks (the blocks have no module syntax or build-specific names).
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
IN_CJS="$DIST/cjs/llm/anthropic/utils/message_inputs.cjs"
IN_ESM="$DIST/esm/llm/anthropic/utils/message_inputs.mjs"
OUT_CJS="$DIST/cjs/llm/anthropic/utils/message_outputs.cjs"
OUT_ESM="$DIST/esm/llm/anthropic/utils/message_outputs.mjs"
CORE_CJS="$DIST/cjs/messages/core.cjs"
CORE_ESM="$DIST/esm/messages/core.mjs"

fail() {
  echo "patch-agents-servertools: $1" >&2
  exit 1
}

for f in "$IN_CJS" "$IN_ESM" "$OUT_CJS" "$OUT_ESM" "$CORE_CJS" "$CORE_ESM"; do
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

# 1. The block types of content_block_start that become chunks.
OLD_OUT='		"server_tool_use",
		"web_search_tool_result"
	].includes(data.content_block.type)'
NEW_OUT='		"server_tool_use",
		"web_search_tool_result",
		"code_execution_tool_result",
		"web_fetch_tool_result",
		"bash_code_execution_tool_result",
		"text_editor_code_execution_tool_result",
		"tool_search_tool_result"
	].includes(data.content_block.type)'

# 2. The list of tool block types at the top of _formatContent.
OLD_TYPES='function _formatContent(message) {
	const toolTypes = [
		"tool_use",
		"tool_result",
		"input_json_delta",
		"server_tool_use",
		"web_search_tool_result",
		"web_search_result"
	];'
NEW_TYPES='function _formatContent(message) {
	// patch-agents-servertools: every server tool result block is a known tool block type
	const serverToolResultTypes = [
		"web_search_tool_result",
		"code_execution_tool_result",
		"web_fetch_tool_result",
		"bash_code_execution_tool_result",
		"text_editor_code_execution_tool_result",
		"tool_search_tool_result"
	];
	const toolTypes = [
		"tool_use",
		"tool_result",
		"input_json_delta",
		"server_tool_use",
		"web_search_result",
		...serverToolResultTypes
	];'

# 3. The rebuilt server_tool_use block.
OLD_USE='					name: rawPart.name ?? "web_search",
					input: coerceAnthropicToolUseInput(rawPart.input ?? rawPart.args)
				};'
NEW_USE='					name: rawPart.name ?? "web_search",
					input: coerceAnthropicToolUseInput(rawPart.input ?? rawPart.args),
					...rawPart.caller !== void 0 ? { caller: rawPart.caller } : {}
				};'

# 4. The rebuilt result block of a server tool.
OLD_RESULT='				const content = rawPart.content;
				if (Array.isArray(content) || content != null && typeof content === "object" && "type" in content && content.type === "web_search_tool_result_error") return {
					type: "web_search_tool_result",
					tool_use_id: rawPart.tool_use_id,
					content
				};
				return null;'
NEW_RESULT='				const rawType = typeof rawPart.type === "string" ? rawPart.type : void 0;
				const content = rawPart.content;
				if (rawType !== void 0 && rawType !== "web_search_tool_result" && serverToolResultTypes.includes(rawType)) {
					if (content == null) return null;
					return {
						type: rawType,
						tool_use_id: rawPart.tool_use_id,
						content,
						...rawPart.caller !== void 0 ? { caller: rawPart.caller } : {}
					};
				}
				if (Array.isArray(content) || content != null && typeof content === "object" && "type" in content && content.type === "web_search_tool_result_error") return {
					type: "web_search_tool_result",
					tool_use_id: rawPart.tool_use_id,
					content,
					...rawPart.caller !== void 0 ? { caller: rawPart.caller } : {}
				};
				return null;'

# 5. The block types the graph keeps in a final Anthropic message.
OLD_ALLOWED='	["anthropic"]: [
		..._allowedTypes,
		"thinking",
		"redacted_thinking",
		"server_tool_use",
		"web_search_tool_result",
		"web_search_result"
	],'
NEW_ALLOWED='	["anthropic"]: [
		..._allowedTypes,
		"thinking",
		"redacted_thinking",
		"server_tool_use",
		"web_search_tool_result",
		"web_search_result",
		"code_execution_tool_result",
		"web_fetch_tool_result",
		"bash_code_execution_tool_result",
		"text_editor_code_execution_tool_result",
		"tool_search_tool_result"
	],'

for f in "$CORE_CJS" "$CORE_ESM"; do
  replace_once "$f" "$OLD_ALLOWED" "$NEW_ALLOWED" "allowed Anthropic block types in modifyContent"
done
for f in "$IN_CJS" "$IN_ESM"; do
  replace_once "$f" "$OLD_TYPES" "$NEW_TYPES" "list of tool block types in _formatContent"
  replace_once "$f" "$OLD_USE" "$NEW_USE" "server_tool_use block in _formatContent"
  replace_once "$f" "$OLD_RESULT" "$NEW_RESULT" "server tool result block in _formatContent"
done
for f in "$OUT_CJS" "$OUT_ESM"; do
  replace_once "$f" "$OLD_OUT" "$NEW_OUT" "block types of content_block_start in _makeMessageChunkFromAnthropicEvent"
done

echo "patch-agents-servertools: server tool result blocks and caller kept when an Anthropic turn is replayed in $DIST"
