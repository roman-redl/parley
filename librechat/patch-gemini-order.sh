#!/bin/sh
# Keeps function calls at their position when @librechat/agents replays a Gemini turn.
#
# Gemini 4 with Google Search grounding plus function declarations sometimes answers one model
# turn with parts in this order: toolCall (server-side GOOGLE_SEARCH_WEB, with a
# thoughtSignature), functionCall(s), toolResponse (with a thoughtSignature). On the next step
# the agent graph sends the history back. Exact replay (restoreGeminiReplayParts) is disabled
# for a turn that holds server-side tool parts, so the fallback converter of one message runs
# (dist/{cjs,esm}/llm/google/utils/common.*). It drops every functionCall block of the message
# content (_convertLangChainContentToPart returns nothing for it) and appends the calls rebuilt
# from tool_calls at the end, so the replayed turn becomes toolCall, toolResponse,
# functionCall(s). Checked against the Gemini API: that order is accepted only when every moved
# call carries a thoughtSignature. The converter adds a placeholder signature only when the turn
# has no stored call signature at all; once one call of the turn has a signature, the others
# go without one, and Google rejects the request with "400 Function call is missing a
# thought_signature in functionCall parts ... function call google:search, position N". The
# original order is accepted with the signatures exactly as the model sent them. The error
# depends on the order the model chose, so it is intermittent.
#
# The patch makes two replacements in each file:
#   1. _convertLangChainContentToPart returns a functionCall block as a placeholder part
#      (marked with a non-enumerable property, so it never reaches the request as is) instead
#      of dropping it;
#   2. the final return of the message converter puts every rebuilt call (it carries the
#      signature, or the placeholder signature, as before) in the place of its functionCall
#      part: matched by functionCall.id when the part has an id, by name when it has none (the
#      first rebuilt call with that name not placed yet). A placeholder that matches no rebuilt
#      call is dropped, as the block was before; any other functionCall part that matches none
#      stays (the old filter kept those). Rebuilt calls not placed this way are appended at the
#      end in their original order: the old behaviour, and the case of a message whose content
#      holds no functionCall blocks.
#
# Drop this patch when the upstream fixes it: check on every upgrade of LibreChat whether
# LibreChat-AI/agents keeps the function-call positions in the fallback converter, or whether
# exact replay supports server-side tool parts.
#
# The script fails if an expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time. Running it twice fails
# too, because the original text is gone after the first run. The cjs and esm builds hold the
# same text (the blocks have no module syntax).
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
FILES="$DIST/cjs/llm/google/utils/common.cjs $DIST/esm/llm/google/utils/common.mjs"

fail() {
  echo "patch-gemini-order: $1" >&2
  exit 1
}

# 1. The functionCall branch of _convertLangChainContentToPart (indented with tabs).
OLD1='	else if ("functionCall" in content) return;'
NEW1='	else if ("functionCall" in content) return Object.defineProperty({ functionCall: content.functionCall }, "parleyPlaceholder", { value: true });'

# 2. The final statement of the message converter. The two Set declarations above it stay.
OLD2='	return [...messageParts.filter((part) => {
		if (!("functionCall" in part) || part.functionCall == null) return true;
		const functionCall = part.functionCall;
		return !(functionCall.id != null && parsedFunctionCallIds.has(functionCall.id) || functionCall.id == null && parsedFunctionCallNames.has(functionCall.name));
	}), ...functionCalls];'
NEW2='	// patch-gemini-order: a rebuilt call takes the place of its functionCall part, so the order of the parts stays as the model sent it
	const unplacedCalls = [...functionCalls];
	const orderedParts = messageParts.flatMap((part) => {
		if (!("functionCall" in part) || part.functionCall == null) return [part];
		const functionCall = part.functionCall;
		const index = unplacedCalls.findIndex((call) => functionCall.id != null ? call.functionCall.id === functionCall.id : call.functionCall.name === functionCall.name);
		if (index !== -1) return unplacedCalls.splice(index, 1);
		return part.parleyPlaceholder === true ? [] : [part];
	});
	return [...orderedParts, ...unplacedCalls];'

for f in $FILES; do
  [ -f "$f" ] || fail "$f not found"
done

# Replace only if each OLD occurs exactly once in the file; then verify the result.
for f in $FILES; do
  OLD1="$OLD1" NEW1="$NEW1" OLD2="$OLD2" NEW2="$NEW2" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    let src = fs.readFileSync(file, "utf8");
    for (const n of ["1", "2"]) {
      const parts = src.split(process.env["OLD" + n]);
      if (parts.length !== 2) {
        console.error("text " + n + " found " + (parts.length - 1) + " times, need exactly 1");
        process.exit(1);
      }
      src = parts.join(process.env["NEW" + n]);
    }
    fs.writeFileSync(file, src);
  ' "$f" || fail "$f: expected text of the message converter not found exactly once"

  # Verify: each new text is present exactly once and the old ones are gone.
  OLD1="$OLD1" NEW1="$NEW1" OLD2="$OLD2" NEW2="$NEW2" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    const src = fs.readFileSync(file, "utf8");
    for (const n of ["1", "2"]) {
      if (src.split(process.env["NEW" + n]).length !== 2 || src.split(process.env["OLD" + n]).length !== 1) process.exit(1);
    }
  ' "$f" || fail "$f: patched text not present as expected after the patch"
done

echo "patch-gemini-order: function calls keep their position in replayed Gemini turns in $DIST"
