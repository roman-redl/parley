#!/bin/sh
# Keeps tool images (artifacts) visible to the model when the tool batch is followed by
# hook messages.
#
# Before every model call @librechat/agents shows the artifacts (images) of the latest tool
# results to the model: projectServingArtifacts (dist/{cjs,esm}/graphs/Graph.*) turns them
# into provider content, but only when the last message of the request is a ToolMessage (the
# same check sits in the guard before the call and in projectAnthropicArtifactContent and
# projectArtifactPayload in messages/core.*). A PostToolBatch hook that returns
# additionalContext (the step budget hook of LibreChat does so once three or fewer tool
# rounds remain) makes ToolNode.* append a HumanMessage with
# additional_kwargs.source = "hook" after the ToolMessages. The last message is then not a
# ToolMessage, projectServingArtifacts returns the request unchanged and a screenshot taken on
# such a step never reaches the model: only the path line of the text part does.
#
# The patch makes the trailing hook messages a tail that is set aside: the projection runs on
# the messages before the tail (so its own "last message is a ToolMessage" checks pass) and
# the tail is put back after the result, in the same order. Without a hook tail the function
# behaves exactly as before; a trailing message that is not a hook message (a user message)
# still switches the projection off. The original function stays as
# projectServingArtifactsBase and is called by the new wrapper, so the fallback request path
# (prepareProviderRequest), which calls the same function, gets the fix too. The guard before
# the call is widened with a check for a hook tail.
#
# The script fails if an expected text is not found exactly once in each file: a LibreChat
# upgrade that changes @librechat/agents must be noticed at build time (and the patch dropped
# if the upstream fixed it). Running it twice fails too, because the original text is gone
# after the first run.
set -eu

DIST="${1:-/app/node_modules/@librechat/agents/dist}"
FILES="$DIST/cjs/graphs/Graph.cjs $DIST/esm/graphs/Graph.mjs"

fail() {
  echo "patch-hook-tail-images: $1" >&2
  exit 1
}

# 1. The head of projectServingArtifacts. The original function is kept under a new name and
# a wrapper with the old name is defined before it (it is only called later, so the order of
# the declarations does not matter). The wrapper takes (candidate, ...args) so that its own
# text does not contain the original head and the check "original text is gone" holds.
OLD_FN='const projectServingArtifacts = (candidate, provider, clientOptions, maxChars) => {'
NEW_FN='const servingHookTailStart = (candidate) => {
				let end = candidate.length;
				while (end > 0 && candidate[end - 1].getType() === "human" && candidate[end - 1].additional_kwargs?.source === "hook") end--;
				return end;
			};
			const hasServingHookTail = (candidate) => servingHookTailStart(candidate) < candidate.length;
			const projectServingArtifacts = (candidate, ...args) => {
				const end = servingHookTailStart(candidate);
				if (end === candidate.length) return projectServingArtifactsBase(candidate, ...args);
				const head = candidate.slice(0, end);
				const projected = projectServingArtifactsBase(head, ...args);
				return projected === head ? candidate : [...projected, ...candidate.slice(end)];
			};
			const projectServingArtifactsBase = (candidate, provider, clientOptions, maxChars) => {'

# 2. The guard before the projection call: also enter when the request ends with hook messages.
OLD_GUARD='if (lastMessageY instanceof '
NEW_GUARD='if (hasServingHookTail(finalMessages) || lastMessageY instanceof '

for f in $FILES; do
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

  # Verify: the new text is present exactly once and the old one is gone.
  OLD="$old" NEW="$new" node -e '
    const fs = require("fs");
    const [file] = process.argv.slice(1);
    const { OLD, NEW } = process.env;
    const src = fs.readFileSync(file, "utf8");
    if (src.split(NEW).length !== 2) process.exit(1);
    if (src.split(OLD).length !== 1) process.exit(2);
  ' "$file" || fail "$file: $what not replaced as expected after the patch"
}

for f in $FILES; do
  replace_once "$f" "$OLD_FN" "$NEW_FN" "projectServingArtifacts definition"
  replace_once "$f" "$OLD_GUARD" "$NEW_GUARD" "artifact projection guard"
done

echo "patch-hook-tail-images: tool images kept visible before trailing hook messages in $DIST"
