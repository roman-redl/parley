#!/bin/sh
# Tells the model, in the stored text of an MCP tool result, that the result carried images.
#
# formatToolContent (dist/index.cjs of @librechat/api) splits an MCP tool result into a text
# part and artifacts: images (a Playwright screenshot, a PNG read by DesktopCommander) become
# artifacts of type image_url, and the text part keeps only a line such as
# "- [Screenshot of viewport](/data/web/page-1.png)". @librechat/agents shows the artifact to
# the model on the very next model call only; later steps replay the text part alone (and only
# the text is stored as tool_call.output in the database). A model that read figures from a
# screenshot then sees just a file path on a later step and may conclude that "the image did
# not reach it" and discard the correct data.
#
# The patch appends a short fixed note to the text part whenever at least one image became an
# artifact: how many images came with the result, that they were shown on the step right after
# the call and that later steps do not keep them. The note is part of the text, so a live run
# and a restored history look the same; it depends neither on time nor on the step. For an
# image-only result the note is the whole text part. The tool result length cap
# (maxToolResultChars) keeps the head and the tail of a long text, so the note at the end
# survives truncation. Only the branch for recognised providers is patched (all providers
# that produce artifacts, anthropic and google included); for the others images are never
# separated into artifacts.
#
# The script fails if the expected line is not found exactly once in the file: a LibreChat
# upgrade that changes @librechat/api must be noticed at build time (and the patch dropped
# if the upstream fixed it). Running it twice fails too, because the original text is gone
# after the first run. @librechat/api ships a single CommonJS build (dist/index.cjs), which
# is what the server loads.
set -eu

DIST="${1:-/app/packages/api/dist}"
FILES="$DIST/index.cjs"

fail() {
  echo "patch-tool-images-note: $1" >&2
  exit 1
}

# The line in formatToolContent that turns collected images into artifacts, and its
# replacement (the note is appended to the text part in the same branch).
OLD='if (imageUrls.length > 0) artifacts = { content: imageUrls };'
NEW='if (imageUrls.length > 0) { artifacts = { content: imageUrls }; currentTextBlock += (currentTextBlock ? "\n" : "") + "[" + imageUrls.length + " image(s) from this result were attached and shown to the model on the step right after this call; images are not kept in later steps of the history.]"; }'

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
  ' "$f" || fail "$f: pattern in formatToolContent not found exactly once"

  # Verify: the new text is present exactly once and the old one is gone.
  [ "$(grep -cF -e "$NEW" "$f")" -eq 1 ] || fail "$f: patched line not present after the patch"
  [ "$(grep -cF -e "$OLD" "$f")" -eq 0 ] || fail "$f: original line still present after the patch"
done

echo "patch-tool-images-note: image note added to tool results in $DIST"
