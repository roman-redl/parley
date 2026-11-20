#!/bin/sh
# Keeps function calls at their position when @librechat/agents replays a Gemini turn.
#
# Gemini with Google Search grounding plus function declarations sometimes answers one model
# turn with parts in this order: toolCall (server-side GOOGLE_SEARCH_WEB, with a
# thoughtSignature), functionCall(s) (the first with a thoughtSignature, parallel ones without),
# toolResponse (with a thoughtSignature). On the next step the agent graph sends the history
# back. Exact replay (restoreGeminiReplayParts) is disabled for a turn that holds server-side
# tool parts, so the fallback converter of one message runs
# (dist/{cjs,esm}/llm/google/utils/common.*): it removes every functionCall part from the
# message content and appends the rebuilt calls at the end. The replayed turn becomes toolCall,
# toolResponse, functionCall(s), and Google rejects it with "400 Function call is missing a
# thought_signature in functionCall parts ... function call google:search, position 2": the
# signatures are validated by position. When the model happens to emit the function call after
# the toolResponse, the reordering is harmless, so the error is intermittent.
#
# The patch replaces the final return of that function. Every rebuilt call (it carries the right
# thoughtSignature) takes the place of its functionCall part in the message parts:
#   - a part that is not a functionCall stays as it is;
#   - a functionCall part is replaced by the matching rebuilt call, with the same matching rule
#     as before: by functionCall.id when the part has an id, by name when it has none (the first
#     rebuilt call with that name that is not placed yet);
#   - a functionCall part that matches no rebuilt call stays as it is (the old filter kept
#     those too);
#   - rebuilt calls not placed this way are appended at the end in their original order (the
#     old behaviour, and the case of a message whose content has no functionCall parts).
#
# Drop this patch when the upstream fixes it: check on every upgrade of LibreChat whether
# LibreChat-AI/agents keeps the function-call positions in the fallback converter, or whether
# exact replay supports server-side tool parts.
#
# The script fails if the expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time. Running it twice fails
# too, because the original text is gone after the first run. The cjs and esm builds hold the
# same text (the block has no module syntax).
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
FILES="$DIST/cjs/llm/google/utils/common.cjs $DIST/esm/llm/google/utils/common.mjs"

fail() {
  echo "patch-gemini-order: $1" >&2
  exit 1
}

# The final statement of the converter (indented with tabs) and its replacement. The two Set
# declarations above it stay untouched.
OLD='	return [...messageParts.filter((part) => {
		if (!("functionCall" in part) || part.functionCall == null) return true;
		const functionCall = part.functionCall;
		return !(functionCall.id != null && parsedFunctionCallIds.has(functionCall.id) || functionCall.id == null && parsedFunctionCallNames.has(functionCall.name));
	}), ...functionCalls];'
NEW='	// patch-gemini-order: a rebuilt call takes the place of its functionCall part, so the order of the parts (and with it the thoughtSignature positions) stays as the model sent it
	const unplacedCalls = [...functionCalls];
	const orderedParts = messageParts.map((part) => {
		if (!("functionCall" in part) || part.functionCall == null) return part;
		const functionCall = part.functionCall;
		const index = unplacedCalls.findIndex((call) => functionCall.id != null ? call.functionCall.id === functionCall.id : call.functionCall.name === functionCall.name);
		return index === -1 ? part : unplacedCalls.splice(index, 1)[0];
	});
	return [...orderedParts, ...unplacedCalls];'

for f in $FILES; do
  [ -f "$f" ] || fail "$f not found"
done

# Replace only if OLD occurs exactly once in the file; then verify the result.
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
  ' "$f" || fail "$f: final return of the message converter not found exactly once"

  # Verify: the new text is present exactly once and the old one is gone.
  OLD="$OLD" NEW="$NEW" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    const { OLD, NEW } = process.env;
    const src = fs.readFileSync(file, "utf8");
    if (src.split(NEW).length !== 2 || src.split(OLD).length !== 1) process.exit(1);
  ' "$f" || fail "$f: patched text not present as expected after the patch"
done

echo "patch-gemini-order: function calls keep their position in replayed Gemini turns in $DIST"
