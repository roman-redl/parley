#!/bin/sh
# Raises the 'high' image resolution limits of LibreChat and fixes the EXIF orientation handling.
#
# resizeImageBuffer() in api/server/services/Files/images/resize.js downscales every uploaded
# image before it is sent to a model. The 'high' mode caps the short side at 768 px and the long
# side at 2000 px (1568 px for the anthropic endpoint). That is far below what current models
# accept: Claude Opus 4.7+ takes up to 2576 px on the long edge and 4784 visual tokens
# (ceil(w/28) * ceil(h/28), about 3.7 MP) before the API downsizes the image itself, Gemini has
# no stated pixel cap. A phone photo or a screenshot of a document lost its fine print here.
#
# New rule for every endpoint: scale down (never up), keep the aspect ratio, long edge <= 2576 px
# and width * height <= 3 700 000. Older Claude models downscale on their side, so a larger image
# only costs upload bytes there.
#
# The original also had an EXIF bug: metadata.width/height are the stored (pre-rotation) values,
# but the image is auto-oriented by .rotate() before .resize(). A portrait phone photo stored as
# landscape with orientation 6 was fitted into a landscape box and came out as 576x768 (4:3). The
# target size is now computed from the oriented dimensions (width and height swapped for EXIF
# orientations 5-8).
#
# The 'low' mode and the custom percentage/px modes are left unchanged.
#
# The script fails if any expected text is not found exactly once: a LibreChat upgrade that
# changes resize.js must be noticed at build time (and the patch dropped if the upstream fixed
# it). Running it twice fails too, because the original text is gone after the first run.
# $1 is the LibreChat app root (default /app) or the path of resize.js itself.
set -eu

TARGET="${1:-/app}"
if [ -d "$TARGET" ]; then
  FILE="$TARGET/api/server/services/Files/images/resize.js"
else
  FILE="$TARGET"
fi
MARKER='parley-patch: image limits'

fail() {
  echo "patch-images: $1" >&2
  exit 1
}

[ -f "$FILE" ] || fail "$FILE not found"
! grep -qF -e "$MARKER" "$FILE" || fail "$FILE is already patched"

# All edits go to a copy that replaces the original only after every check passed, so a failed
# run leaves the file untouched.
# The .js suffix is needed by node --check to treat the file as CommonJS.
WORK="$FILE.parley-new.js"
cp "$FILE" "$WORK"

# Replaces OLD with NEW in $WORK, only if OLD occurs exactly once. $1 names the piece in errors.
replace_once() {
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
  ' "$WORK" || { rm -f "$WORK"; fail "$1 not found exactly once in $FILE"; }
}

# JSDoc line that states the limit.
OLD=" *                                      'high' for a maximum of 768x2000 resolution,"
NEW=" *                                      'high' for a maximum of 2576 px on the long side and 3.7 MP,"
replace_once "JSDoc line of the 'high' resolution"

# Short side limit: replaced by the pixel budget.
OLD='  const maxShortSideHighRes = 768;'
NEW='  const maxPixelsHighRes = 3_700_000;'
replace_once "maxShortSideHighRes constant"

# Long side limit: the same for every endpoint.
OLD="  const maxLongSideHighRes = endpoint === EModelEndpoint.anthropic ? 1568 : 2000;"
NEW='  const maxLongSideHighRes = 2576;'
replace_once "maxLongSideHighRes constant"

# The whole 'high' branch up to the assignment of the computed size.
OLD="$(cat <<'EOF_OLD'
  } else if (resolution === 'high') {
    const metadata = await sharp(inputBuffer).metadata();
    const isWidthShorter = metadata.width < metadata.height;

    if (isWidthShorter) {
      // Width is the shorter side
      newWidth = Math.min(metadata.width, maxShortSideHighRes);
      // Calculate new height to maintain aspect ratio
      newHeight = Math.round((metadata.height / metadata.width) * newWidth);
      // Ensure the long side does not exceed the maximum allowed
      if (newHeight > maxLongSideHighRes) {
        newHeight = maxLongSideHighRes;
        newWidth = Math.round((metadata.width / metadata.height) * newHeight);
      }
    } else {
      // Height is the shorter side
      newHeight = Math.min(metadata.height, maxShortSideHighRes);
      // Calculate new width to maintain aspect ratio
      newWidth = Math.round((metadata.width / metadata.height) * newHeight);
      // Ensure the long side does not exceed the maximum allowed
      if (newWidth > maxLongSideHighRes) {
        newWidth = maxLongSideHighRes;
        newHeight = Math.round((metadata.height / metadata.width) * newWidth);
      }
    }

    resizeOptions.width = newWidth;
    resizeOptions.height = newHeight;
EOF_OLD
)"
NEW="$(cat <<'EOF_NEW'
  } else if (resolution === 'high') {
    // parley-patch: image limits
    const metadata = await sharp(inputBuffer).metadata();
    // EXIF orientations 5-8 turn the image by 90 degrees: .rotate() below applies them before
    // .resize(), so the target size must be computed from the oriented dimensions.
    const isRotated = metadata.orientation >= 5;
    const srcWidth = isRotated ? metadata.height : metadata.width;
    const srcHeight = isRotated ? metadata.width : metadata.height;
    // One factor for both limits (long edge and pixel budget), never above 1: no upscaling.
    const scale = Math.min(
      1,
      maxLongSideHighRes / Math.max(srcWidth, srcHeight),
      Math.sqrt(maxPixelsHighRes / (srcWidth * srcHeight)),
    );
    // floor, not round: the limits must hold exactly.
    newWidth = Math.max(1, Math.floor(srcWidth * scale));
    newHeight = Math.max(1, Math.floor(srcHeight * scale));

    resizeOptions.width = newWidth;
    resizeOptions.height = newHeight;
EOF_NEW
)"
replace_once "'high' resolution branch"

# Verify: the file is valid JavaScript, the marker is present once, the old limits are gone.
node --check "$WORK" || { rm -f "$WORK"; fail "patched $FILE is not valid JavaScript"; }
[ "$(grep -cF -e "$MARKER" "$WORK")" -eq 1 ] || { rm -f "$WORK"; fail "marker '$MARKER' not present exactly once after the patch"; }
[ "$(grep -cF -e 'maxShortSideHighRes' "$WORK")" -eq 0 ] || { rm -f "$WORK"; fail "maxShortSideHighRes still present after the patch"; }
[ "$(grep -cF -e '1568' "$WORK")" -eq 0 ] || { rm -f "$WORK"; fail "the 1568 px limit is still present after the patch"; }

mv "$WORK" "$FILE"

echo "patch-images: 'high' limits 2576 px / 3.7 MP, EXIF orientation applied before sizing in $FILE"
