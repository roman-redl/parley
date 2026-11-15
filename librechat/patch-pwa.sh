#!/bin/sh
# Sets the PWA theme colour in the LibreChat client build.
#
# The Android PWA paints its status bar with theme_color from manifest.webmanifest
# (LibreChat default #009688, a green bar). The same colour as <meta name="theme-color">
# in index.html is #171717.
#
# The service worker (sw.js) precaches manifest.webmanifest together with a revision
# (the md5 of the file content, as workbox computes it). A changed file with the old
# revision would be ignored by installed clients, so the revision is rewritten too.
#
# The script fails if any expected pattern is missing: a LibreChat upgrade that changes
# the manifest or the service worker must be noticed at build time, not on a phone.
set -eu

DIST="${1:-/app/client/dist}"
MANIFEST="$DIST/manifest.webmanifest"
SW="$DIST/sw.js"
OLD_COLOR='#009688'
NEW_COLOR='#171717'

fail() {
  echo "patch-pwa: $1" >&2
  exit 1
}

[ -f "$MANIFEST" ] || fail "$MANIFEST not found"
[ -f "$SW" ] || fail "$SW not found"

# Exactly one theme_color, with the expected old value.
COLOR_RE='"theme_color" *: *"'"$OLD_COLOR"'"'
[ "$(grep -Eo "$COLOR_RE" "$MANIFEST" | wc -l)" -eq 1 ] \
  || fail "theme_color $OLD_COLOR not found exactly once in manifest.webmanifest"

# Exactly one precache entry of the manifest in the service worker.
REV_RE='url:"manifest\.webmanifest",revision:"[0-9a-f]{32}"'
[ "$(grep -Eo "$REV_RE" "$SW" | wc -l)" -eq 1 ] \
  || fail "precache entry of manifest.webmanifest not found exactly once in sw.js"

# Precompressed copies of the service worker would keep serving the old one.
for ext in gz br; do
  [ ! -e "$SW.$ext" ] || fail "$SW.$ext exists: it would need the same patch"
done

# -i.bak works the same in GNU, busybox and BSD sed.
sed -i.bak -E "s/(\"theme_color\" *: *\")$OLD_COLOR(\")/\1$NEW_COLOR\2/" "$MANIFEST"
rm -f "$MANIFEST.bak"

node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (m.theme_color !== process.argv[2]) { console.error("theme_color is " + m.theme_color); process.exit(1); }
' "$MANIFEST" "$NEW_COLOR" || fail "patched manifest.webmanifest is invalid or has the wrong theme_color"

NEW_REV="$(md5sum "$MANIFEST" | cut -d' ' -f1)"
[ "${#NEW_REV}" -eq 32 ] || fail "could not compute md5 of manifest.webmanifest"

sed -i.bak -E "s/(url:\"manifest\.webmanifest\",revision:\")[0-9a-f]{32}(\")/\1$NEW_REV\2/" "$SW"
rm -f "$SW.bak"
grep -q "url:\"manifest\.webmanifest\",revision:\"$NEW_REV\"" "$SW" \
  || fail "revision in sw.js was not updated"

echo "patch-pwa: theme_color $NEW_COLOR, manifest revision $NEW_REV"
