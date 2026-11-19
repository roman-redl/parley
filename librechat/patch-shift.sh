#!/bin/sh
# Removes the "hold Shift for instant Archive and Delete" feature from the LibreChat client.
#
# client/src/hooks/Generic/useShiftKey.ts listens to window keydown/keyup/blur and tells the
# active conversation in the sidebar (Convo.tsx, ConvoOptions.tsx) that Shift is held; while
# it is, the row shows Archive and Delete buttons, and Delete acts without confirmation. The
# hook does not check focus, so typing a capital letter in the chat input flashes those buttons.
# Archive and Delete stay available in the "..." menu of the conversation.
#
# The client is a prebuilt bundle, so the script injects one inline <script> before </head> of
# index.html. It registers a capture-phase keydown listener on window (first in the event path,
# registered before the bundle loads) that calls stopImmediatePropagation() for the Shift key
# itself, so the hook never sees Shift as held. Typing capitals, Shift+Enter, Shift+click and
# every Shift-based shortcut are separate events that carry shiftKey, so they are unaffected.
#
# Checked against the v0.8.8 sources: nothing else reacts to a bare Shift keydown.
# bindingFromEvent() (utils/shortcuts.ts) ignores modifier-only events, so the global shortcuts
# (useKeyboardShortcuts.ts, window keydown) never needed them, and Ctrl+Shift+X chords match on
# the final key with shiftKey set. The one consumer is the shortcut recorder in the settings
# (ShortcutRecorder.tsx, a React onKeyDown on the element with data-testid
# "shortcut-recorder-*"): it previews modifiers while they are held. The listener therefore
# leaves keydown events that target that element alone. The stopped event is not cancelled
# (no preventDefault), so the browser behaviour of the key is unchanged.
#
# The server reads index.html once at startup and serves it from memory, and precompressed
# index.html.br and index.html.gz sit next to it (a static handler may serve those instead), so
# both are regenerated from the patched file. A service worker that precached index.html would
# keep serving the old copy to installed clients; the script fails if sw.js mentions it.
#
# The script fails if an expected pattern is missing or the marker is already present: a
# LibreChat upgrade that changes index.html or the service worker must be noticed at build time.
set -eu

DIST="${1:-/app/client/dist}"
INDEX="$DIST/index.html"
SW="$DIST/sw.js"
MARKER='data-parley-patch="no-shift-actions"'
SNIPPET='(function(){window.addEventListener("keydown",function(e){if(e.key!=="Shift")return;var t=e.target;if(t&&t.closest&&t.closest("[data-testid^=shortcut-recorder-]"))return;e.stopImmediatePropagation();},true);})();'

fail() {
  echo "patch-shift: $1" >&2
  exit 1
}

[ -f "$INDEX" ] || fail "$INDEX not found"
[ -f "$SW" ] || fail "$SW not found"

# Not patched yet, and exactly one </head> to inject before.
[ "$(grep -Fo "$MARKER" "$INDEX" | wc -l)" -eq 0 ] \
  || fail "marker already present in index.html: the patch is applied twice"
[ "$(grep -Fo '</head>' "$INDEX" | wc -l)" -eq 1 ] \
  || fail "</head> not found exactly once in index.html"

# index.html must not be precached: installed clients would keep the old copy.
if grep -Fq 'index.html' "$SW"; then
  fail "sw.js mentions index.html: it may be precached and would need a revision update"
fi

MARKER="$MARKER" SNIPPET="$SNIPPET" node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const [file] = process.argv.slice(1);
  const { MARKER, SNIPPET } = process.env;
  const src = fs.readFileSync(file, "utf8");
  const parts = src.split("</head>");
  if (parts.length !== 2) {
    console.error("</head> found " + (parts.length - 1) + " times, need exactly 1");
    process.exit(1);
  }
  const out = parts.join("<script " + MARKER + ">" + SNIPPET + "</script></head>");
  fs.writeFileSync(file, out);
  // Precompressed copies must match the patched file, or a stale one could be served.
  fs.writeFileSync(file + ".br", zlib.brotliCompressSync(Buffer.from(out, "utf8")));
  fs.writeFileSync(file + ".gz", zlib.gzipSync(Buffer.from(out, "utf8"), { level: 9 }));
' "$INDEX" || fail "could not patch $INDEX"

# Verify: marker once, script right before </head>, compressed copies equal the patched file.
[ "$(grep -Fo "$MARKER" "$INDEX" | wc -l)" -eq 1 ] || fail "marker not present exactly once after the patch"
[ "$(grep -Fo '</head>' "$INDEX" | wc -l)" -eq 1 ] || fail "</head> count changed after the patch"
grep -Fq "$SNIPPET</script></head>" "$INDEX" || fail "script is not placed before </head>"
node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const [file] = process.argv.slice(1);
  const plain = fs.readFileSync(file);
  const same = (a, b) => Buffer.compare(a, b) === 0;
  if (!same(zlib.brotliDecompressSync(fs.readFileSync(file + ".br")), plain)) process.exit(1);
  if (!same(zlib.gunzipSync(fs.readFileSync(file + ".gz")), plain)) process.exit(1);
' "$INDEX" || fail "index.html.br or index.html.gz does not match the patched index.html"

echo "patch-shift: Shift keydown stopped for the sidebar hook in $INDEX (.br and .gz regenerated)"
