#!/bin/sh
# Keeps tool images (artifacts) visible to Anthropic models for the rest of the reply.
#
# A tool such as a Playwright screenshot returns an image artifact. @librechat/agents shows
# the artifacts of tool results to the model only on the one model call that follows the tool
# batch: projectAnthropicArtifactContent (dist/{cjs,esm}/messages/core.*) projects only the
# ToolMessages after the latest AI message with tool calls, and both it and
# projectServingArtifacts (dist/{cjs,esm}/graphs/Graph.*) require the last message of the
# request to be a ToolMessage (the same check sits in the guard before the call). On every
# later step of the same reply the model gets the text part alone, "[Screenshot of viewport]
# (/data/web/...png)": it concludes that it never saw the image and discards figures it had
# read correctly. A text note about the attachment and prompt wording did not stop the model
# from discarding figures it had read; keeping the images visible did (with fewer model calls
# and a lower cost). Tool messages of earlier turns are rebuilt from the database without
# artifacts, so the effect is limited to the current reply. The projection no longer needs a
# ToolMessage last either, so hook messages that follow the tool results (the step budget hook
# appends a HumanMessage with additional_kwargs.source = "hook") no longer hide the images from
# the model.
#
# Only the images of the last 10 tool results that carry an artifact are kept (KEEP in the
# injected code, counted from the end of the request). Two reasons. Anthropic caps every image
# at 2000x2000 px once a request holds more than 20 images: a tall full-page screenshot, or an
# uploaded photo up to 2576 px (patch-images.sh) in the history, would then fail every later
# call with a 400 and lose the reply. And when the projected request does not fit the context
# budget, the graph falls back to a request without any artifacts, so fewer kept images make
# that fallback rarer.
#
# Three changes, all for the Anthropic path (isAnthropicLike) only:
#   1. messages/core.*, projectAnthropicArtifactContent: the function no longer looks for the
#      latest AI message with tool calls and no longer requires a ToolMessage last; it walks
#      the request from the end and projects the artifacts of the last KEEP (10) ToolMessages
#      that carry one.
#   2. graphs/Graph.*, projectServingArtifacts: the Anthropic branch moves before the
#      "last message is a ToolMessage" check, so it runs on every call.
#   3. graphs/Graph.*, the guard before the projection call: also enters for an Anthropic
#      provider, not only when the last message is a ToolMessage.
# The size checks stay as they were: the artifact payload is still bounded by the tool result
# budget and is left out, with a warning in the log, if it does not fit the context budget.
#
# Google and OpenAI keep the upstream behaviour, accepted on purpose: their projection
# (projectArtifactPayload) appends a HumanMessage with the images after the latest tool batch,
# a different structure that cannot be repeated on every step the same way. There the image is
# visible on the next model call only, and a step budget hook message after the tool results
# hides it.
#
# The upstream does not change this: LibreChat-AI/agents PR #677 only fixes the image size
# budget and leaves the handling of tool images across steps untouched.
#
# The script fails if an expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time (and the patch dropped
# if the upstream fixed it). Running it twice fails too, because the original text is gone
# after the first run. The cjs and esm builds differ only in identifier prefixes
# (_langchain_core_messages., require_llm., require_core.), which are set per build below.
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
CORE_CJS="$DIST/cjs/messages/core.cjs"
CORE_ESM="$DIST/esm/messages/core.mjs"
GRAPH_CJS="$DIST/cjs/graphs/Graph.cjs"
GRAPH_ESM="$DIST/esm/graphs/Graph.mjs"

fail() {
  echo "patch-tool-images-run: $1" >&2
  exit 1
}

for f in "$CORE_CJS" "$CORE_ESM" "$GRAPH_CJS" "$GRAPH_ESM"; do
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

# 1. projectAnthropicArtifactContent: from the "last message is a ToolMessage" check through
# the loop header (indented with tabs), the artifact condition inside the loop and the first
# statement of its body (the counter of projected messages).
# $1 = file, $2 = prefix of the LangChain message classes in the build.
patch_core() {
  file="$1"
  M="$2"

  OLD_HEAD="	const lastMessage = messages[messages.length - 1];
	if (!(lastMessage instanceof ${M}ToolMessage)) return messages;
	const latestAIParentIndex = findLastIndex(messages, (msg) => ((msg instanceof ${M}AIMessage || msg instanceof ${M}AIMessageChunk) && (msg.tool_calls?.length ?? 0) > 0 && msg.tool_calls?.some((tc) => tc.id === lastMessage.tool_call_id)) ?? false);
	if (latestAIParentIndex === -1) return messages;
	const message = messages[latestAIParentIndex];
	const toolCallIdSet = /* @__PURE__ */ new Set();
	if (message.tool_calls) {
		for (const tc of message.tool_calls) if (tc.id != null) toolCallIdSet.add(tc.id);
	}
	let formattedMessages;
	for (let j = latestAIParentIndex + 1; j < messages.length; j++) {"
  NEW_HEAD="	// patch-tool-images-run: the artifacts of the last KEEP tool results of the request, not only the latest batch
	const KEEP = 10;
	let kept = 0;
	let formattedMessages;
	for (let j = messages.length - 1; j >= 0 && kept < KEEP; j--) {"

  OLD_COND='toolCallIdSet.has(msg.tool_call_id) && msg.artifact != null'
  NEW_COND='msg.artifact != null'

  OLD_BODY='			const artifactContent = typeof msg.artifact.content === "string"'
  NEW_BODY="			kept++;
$OLD_BODY"

  replace_once "$file" "$OLD_HEAD" "$NEW_HEAD" "head of projectAnthropicArtifactContent"
  replace_once "$file" "$OLD_COND" "$NEW_COND" "artifact condition in projectAnthropicArtifactContent"
  replace_once "$file" "$OLD_BODY" "$NEW_BODY" "start of the projection body in projectAnthropicArtifactContent"
}

# 2 and 3. projectServingArtifacts and the guard before its call.
# $1 = file, $2 = prefix of the LangChain message classes, $3 = prefix of the llm helpers
# (isAnthropicLike), $4 = prefix of the messages/core helpers (projectAnthropicArtifactContent).
patch_graph() {
  file="$1"
  M="$2"
  L="$3"
  C="$4"

  OLD_FN="				if (!(candidate[candidate.length - 1] instanceof ${M}ToolMessage)) return candidate;
				if (${L}isAnthropicLike(provider, clientOptions)) return trackProviderMessageOrigins(candidate, ${C}projectAnthropicArtifactContent(candidate, maxChars));"
  NEW_FN="				if (${L}isAnthropicLike(provider, clientOptions)) return trackProviderMessageOrigins(candidate, ${C}projectAnthropicArtifactContent(candidate, maxChars));
				if (!(candidate[candidate.length - 1] instanceof ${M}ToolMessage)) return candidate;"

  OLD_GUARD="if (lastMessageY instanceof ${M}ToolMessage) {
				const artifactCandidate"
  NEW_GUARD="if (lastMessageY instanceof ${M}ToolMessage || ${L}isAnthropicLike(agentContext.provider, agentContext.clientOptions)) {
				const artifactCandidate"

  replace_once "$file" "$OLD_FN" "$NEW_FN" "projectServingArtifacts Anthropic branch"
  replace_once "$file" "$OLD_GUARD" "$NEW_GUARD" "artifact projection guard"
}

patch_core "$CORE_CJS" "_langchain_core_messages."
patch_core "$CORE_ESM" ""
patch_graph "$GRAPH_CJS" "_langchain_core_messages." "require_llm." "require_core."
patch_graph "$GRAPH_ESM" "" "" ""

echo "patch-tool-images-run: tool images (last 10 tool results) kept visible to Anthropic models for the whole reply in $DIST"
