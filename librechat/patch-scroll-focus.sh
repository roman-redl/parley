#!/bin/sh
# Makes keyboard scrolling of the conversation work: PageUp, PageDown, Space, Shift+Space, the
# arrows, Home and End after a click on the message text, and PageUp and PageDown in the composer.
#
# Two things break it in the v0.8.9 client:
#   - A mouse click on message text moves focus to the pane wrapper <div data-testid="app-pane"
#     tabindex="-1" class="... overflow-hidden"> (client/src/routes/Root.tsx, "focus target of last
#     resort when the drawer closes"): the nearest focusable ancestor of the text. It is an
#     ancestor of the message scroller and does not scroll itself, so every scrolling key does
#     nothing, and nobody cancels these keydown events.
#   - After a conversation opens or a message is sent, focus is in the composer
#     (textarea#prompt-textarea), where PageUp and PageDown only move the caret.
#
# The message scroller is <div class="h-full w-full scrollbar-gutter-stable overflow-y-auto">
# (packages/chat/src/components/messages/MessagesView.tsx; the classes come from cn(...) and
# [overflow-anchor:none] is added while the message list is windowed). It has no tabindex. It sits
# inside the element with data-chat-pane (packages/chat/src/core/pane.ts: getFocusedChatPane() is
# the closest pane of document.activeElement, and the pane-scoped keyboard shortcuts rely on it),
# so focus has to stay inside that pane: focusing the scroller keeps it there.
#
# The client is a prebuilt bundle, so the script injects one <style> and one <script> before
# </head> of index.html:
#   - the style removes the focus outline of the scroller (marked with data-parley-scroll);
#   - the script gives every message scroller tabindex="-1" (focusable by a click, not part of the
#     Tab order). A click on message text then focuses the scroller, the nearest focusable
#     ancestor, instead of the pane wrapper, and the browser scrolls it with the keys. Checked live
#     on v0.8.9: with tabIndex -1 on the scroller all the keys above scroll the conversation and
#     document.activeElement stays inside data-chat-pane. React creates the element again when the
#     conversation changes or a new chat opens, so a MutationObserver (childList, subtree) schedules
#     one coalesced pass (requestAnimationFrame, setTimeout while the tab is hidden) that marks the
#     scrollers lacking a tabindex; the pass is one querySelectorAll on the pane selector. The
#     script runs in <head> before the bundle, so the observer is attached to documentElement.
#   - the same script handles PageUp and PageDown in the composer: a keydown listener on window in
#     the bubble phase, so composer popups that handle keys in React and call preventDefault win
#     (an event with defaultPrevented is skipped). For textarea#prompt-textarea, no modifier key and
#     no IME composition, it scrolls the scroller of the same pane by 87.5% of its height (smooth;
#     instant with prefers-reduced-motion) and cancels the key, so the caret stays and focus stays
#     in the composer. The arrows in the composer are left alone: they move the caret, and ArrowUp
#     in an empty composer opens editing of the last message (upstream feature).
#
# Checked against the client bundle (the minified files, searched generically: the names are
# hashed): the class string of the scroller occurs exactly once (one component renders it, so the
# selector of the script cannot match anything else, and a second occurrence would mean the markup
# changed); data-chat-pane is set as a prop and read by a closest("[data-chat-pane]") selector;
# the composer id prompt-textarea is there; the pane wrapper with data-testid app-pane and
# tabIndex -1, the cause, occurs exactly once. The script fails if any of these is gone: if only
# app-pane is, upstream may have fixed the focus target, so check whether the patch is still needed.
#
# The server reads index.html once at startup and serves it from memory, and precompressed
# index.html.br and index.html.gz sit next to it (a static handler may serve those instead), so
# both are regenerated from the patched file. A service worker that precached index.html would
# keep serving the old copy to installed clients; the script fails if sw.js mentions it.
#
# Run it after patch-shift.sh and patch-timestamps.sh: it expects its own block directly before
# </head>, and each of those scripts checks the same for its own block right after injecting it.
#
# The script fails if an expected pattern is missing or the marker is already present: a
# LibreChat upgrade that changes index.html, the bundle or the service worker must be noticed at
# build time.
set -eu

DIST="${1:-/app/client/dist}"
INDEX="$DIST/index.html"
SW="$DIST/sw.js"
MARKER='data-parley-patch="scroll-focus"'

fail() {
  echo "patch-scroll-focus: $1" >&2
  exit 1
}

STYLE=$(cat <<'EOF'
[data-parley-scroll]:focus{outline:none}
EOF
)

SCRIPT=$(cat <<'EOF'
(function () {
  try {
    var SCROLLER = "[data-chat-pane] .h-full.w-full.scrollbar-gutter-stable.overflow-y-auto";

    function mark() {
      try {
        var els = document.querySelectorAll(SCROLLER);
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el.hasAttribute("tabindex")) continue;
          el.tabIndex = -1;
          el.setAttribute("data-parley-scroll", "");
        }
      } catch (e) {}
    }

    var pending = false;
    function run() {
      pending = false;
      mark();
    }
    function schedule() {
      if (pending) return;
      pending = true;
      if (document.hidden) setTimeout(run, 0);
      else requestAnimationFrame(run);
    }

    function start() {
      try {
        new MutationObserver(schedule).observe(document.documentElement, {
          childList: true, subtree: true
        });
        mark();
      } catch (e) {}
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();

    window.addEventListener("keydown", function (e) {
      try {
        if (e.defaultPrevented || e.isComposing) return;
        if (e.key !== "PageUp" && e.key !== "PageDown") return;
        if (e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return;
        var t = e.target;
        if (!t || t.id !== "prompt-textarea" || !t.closest) return;
        var pane = t.closest("[data-chat-pane]");
        var scroller = pane && pane.querySelector(SCROLLER);
        if (!scroller) return;
        e.preventDefault();
        var step = Math.max(scroller.clientHeight * 0.875, 40);
        var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        scroller.scrollBy({
          top: e.key === "PageUp" ? -step : step,
          behavior: reduced ? "auto" : "smooth"
        });
      } catch (err) {}
    }, false);
  } catch (e) {}
})();
EOF
)

[ -f "$INDEX" ] || fail "$INDEX not found"
[ -f "$SW" ] || fail "$SW not found"

# Neither tag may be able to end early.
case "$STYLE" in *'</style'*) fail "internal error: the style contains a closing tag" ;; esac
case "$SCRIPT" in *'</script'*) fail "internal error: the script contains a closing tag" ;; esac

# Not patched yet, and exactly one </head> to inject before.
[ "$(grep -Fo "$MARKER" "$INDEX" | wc -l)" -eq 0 ] \
  || fail "marker already present in index.html: the patch is applied twice"
[ "$(grep -Fo '</head>' "$INDEX" | wc -l)" -eq 1 ] \
  || fail "</head> not found exactly once in index.html"

# index.html must not be precached: installed clients would keep the old copy.
if grep -Fq 'index.html' "$SW"; then
  fail "sw.js mentions index.html: it may be precached and would need a revision update"
fi

# The markup the patch relies on must still be in the client bundle.
[ -d "$DIST/assets" ] || fail "$DIST/assets not found"
node - "$DIST/assets" <<'EOF' || fail "the client bundle no longer matches what the patch relies on"
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const js = fs.readdirSync(dir)
  .filter((n) => n.endsWith(".js"))
  .map((n) => fs.readFileSync(path.join(dir, n), "utf8"))
  .join("\n");
const count = (text, pattern) => text.split(pattern).length - 1;
let bad = 0;
const check = (name, pattern, exactlyOnce, hint) => {
  const n = count(js, pattern);
  if (exactlyOnce ? n !== 1 : n < 1) {
    console.error("expected " + (exactlyOnce ? "exactly one" : "at least one") + " match, found " + n + ": " + name + (hint ? " (" + hint + ")" : ""));
    bad++;
  }
};
// The message scroller (MessagesView): one component, so the selector of the script matches
// nothing else.
check("message scroller class string",
  "h-full w-full scrollbar-gutter-stable overflow-y-auto", true);
// The pane attribute: set as a prop, and read through closest("[data-chat-pane]") by
// getFocusedChatPane().
check("data-chat-pane prop", '"data-chat-pane":', false);
check("data-chat-pane selector", "[data-chat-pane]", false);
// The composer textarea id.
check("composer id", "id:`prompt-textarea`", false);
// The cause: the pane wrapper that takes the focus of a click on message text.
check("app-pane wrapper with tabIndex -1",
  "\"data-testid\":`app-pane`,tabIndex:-1", true,
  "if it is gone, upstream may have fixed the focus target: check whether the patch is still needed");
process.exit(bad ? 1 : 0);
EOF

STYLE="$STYLE" SCRIPT="$SCRIPT" MARKER="$MARKER" node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const [file] = process.argv.slice(1);
  const { STYLE, SCRIPT, MARKER } = process.env;
  const src = fs.readFileSync(file, "utf8");
  const parts = src.split("</head>");
  if (parts.length !== 2) {
    console.error("</head> found " + (parts.length - 1) + " times, need exactly 1");
    process.exit(1);
  }
  const block = "<style " + MARKER + ">" + STYLE + "</style><script " + MARKER + ">" + SCRIPT + "</script>";
  const out = parts.join(block + "</head>");
  fs.writeFileSync(file, out);
  // Precompressed copies must match the patched file, or a stale one could be served.
  fs.writeFileSync(file + ".br", zlib.brotliCompressSync(Buffer.from(out, "utf8")));
  fs.writeFileSync(file + ".gz", zlib.gzipSync(Buffer.from(out, "utf8"), { level: 9 }));
' "$INDEX" || fail "could not patch $INDEX"

# Verify: both tags once, the block right before </head>, compressed copies equal the patched file.
# Each tag is counted on its own: index.html is one line, and the busybox grep of the image prints
# only the first match of a line with -o, so a count of two markers would read as one.
[ "$(grep -Fo "<style $MARKER>" "$INDEX" | wc -l)" -eq 1 ] || fail "style tag not present exactly once after the patch"
[ "$(grep -Fo "<script $MARKER>" "$INDEX" | wc -l)" -eq 1 ] || fail "script tag not present exactly once after the patch"
[ "$(grep -Fo '</head>' "$INDEX" | wc -l)" -eq 1 ] || fail "</head> count changed after the patch"
STYLE="$STYLE" SCRIPT="$SCRIPT" MARKER="$MARKER" node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const [file] = process.argv.slice(1);
  const { STYLE, SCRIPT, MARKER } = process.env;
  const plain = fs.readFileSync(file);
  const block = "<style " + MARKER + ">" + STYLE + "</style><script " + MARKER + ">" + SCRIPT + "</script></head>";
  if (!plain.toString("utf8").includes(block)) process.exit(2);
  const same = (a, b) => Buffer.compare(a, b) === 0;
  if (!same(zlib.brotliDecompressSync(fs.readFileSync(file + ".br")), plain)) process.exit(3);
  if (!same(zlib.gunzipSync(fs.readFileSync(file + ".gz")), plain)) process.exit(3);
' "$INDEX" || fail "the style and script are not placed before </head>, or index.html.br or index.html.gz does not match the patched index.html"

echo "patch-scroll-focus: message list focusable by click, PageUp/PageDown scroll it from the composer in $INDEX (.br and .gz regenerated)"
