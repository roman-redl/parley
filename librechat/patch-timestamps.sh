#!/bin/sh
# Makes message timestamps always visible, shows them on user messages too, and rewrites their text
# in the format "14:35", "вчера, 14:35", "18 нояб., 14:35", "18 нояб. 2025, 14:35".
#
# The LibreChat client renders a message timestamp as <time class="message-timestamp ..."
# datetime="ISO">TEXT</time> (packages/chat/src/components/messages/MessageTimestamp.tsx, placed
# by MessageRow.tsx next to it). TEXT is "10 минут назад" for messages under 24 hours old (React
# re-renders it every minute) and an absolute date otherwise; `title` is set only for the recent
# ones. The bundled CSS hides every timestamp until the message is hovered (.message-render
# .message-timestamp {opacity:0} inside @media (hover:hover) and @media not all and
# (any-pointer:coarse), as plain unlayered CSS). On bot messages the <time> sits in the visible
# header row (div.agent-turn > h2 > time); on user messages it sits in a screen-reader-only
# header (div.user-turn > h2.sr-only > time), so it is never visible; system messages keep theirs
# in a span.sr-only, and a bot turn with a hidden author line (interface.messageAuthor:
# whenDifferent, not set here) in an h2.sr-only: this patch leaves both alone. The steer-part (a
# user turn shown while a message is steered) has an h2.sr-only too but no time, so the style
# matches only an h2.sr-only that directly contains a timestamp (:has(> time.message-timestamp)).
#
# The client is a prebuilt bundle, so the script injects one <style> and one <script> before
# </head> of index.html:
#   - the style forces opacity 1 on the timestamps and turns the user header from the bundle's
#     .sr-only into a plain block (every property of that rule is undone: position, width,
#     height, margin, padding, overflow, clip-path, white-space, border-width; font-size 0 makes
#     its label text nodes vanish, the <time> inside gets 12px/16px again and a zero
#     margin-inline-start, which replaces the ms-2 of the component). The user turn is a
#     right-aligned column, so the time ends up above the bubble, on the right. Why the style
#     wins: the bundle's .sr-only and ms-2 sit in @layer utilities, and any unlayered declaration
#     beats a layered one whatever the specificity (the injected style is unlayered); the hide
#     rule is unlayered with the specificity of two classes, so the opacity override carries
#     !important, which beats every normal declaration, and no !important declaration of the
#     bundle competes with it;
#   - the script rewrites the text of every `.message-render time.message-timestamp[datetime]`
#     with Intl (locale "ru", hardcoded: the users are Russian; local time zone of the device,
#     24-hour clock) and sets `title` to the full date and time. The timestamp of the LAST bot
#     message in the document shows relative time ("только что", "2 минуты назад") while it is
#     younger than 5 minutes. A future date (clock skew) counts as now.
#   - React rewrites the text and the title on its own re-renders and messages appear as the chat
#     loads or streams, so a MutationObserver (childList, subtree, characterData) schedules one
#     coalesced update, and a 15 s interval advances the relative label. Writes are made only when
#     the value differs, so the observer does not loop; the text is changed through nodeValue of
#     the existing single Text child (React keeps a reference to that node), not by replacing it.
#
# Checked against the v0.8.9 sources and client (the minified bundle): the component with the
# class string below, the CSS rule that hides the timestamps and the exact definition of
# .sr-only (clip-path: inset(50%) and no clip, so the injected style undoes every property of
# it), and the markup of MessageRow, which lives in a separate chunk: the expressions choosing
# "user-turn" (isUserSide) or "agent-turn" (not user side and not system), the user header (h2
# with className sr-only holding prefix, label and the timestamp component) and the bot header
# (timestamp component with className "ms-auto shrink-0 font-normal"; the "me-auto" variant
# belongs to user-side turns that show their author, which the main chat has none of, and is
# not relied on). The script fails if any of these is gone, because the style and the script
# then no longer match the client. The checks search every assets/*.css and assets/*.js
# generically (the file names are hashed): the rules, the class string and the MessageRow
# fragments must occur exactly once, the other fragments at least once.
#
# The server reads index.html once at startup and serves it from memory, and precompressed
# index.html.br and index.html.gz sit next to it (a static handler may serve those instead), so
# both are regenerated from the patched file. A service worker that precached index.html would
# keep serving the old copy to installed clients; the script fails if sw.js mentions it.
#
# The script fails if an expected pattern is missing or the marker is already present: a
# LibreChat upgrade that changes index.html, the bundle or the service worker must be noticed at
# build time.
set -eu

DIST="${1:-/app/client/dist}"
INDEX="$DIST/index.html"
SW="$DIST/sw.js"
MARKER='data-parley-patch="timestamps"'

fail() {
  echo "patch-timestamps: $1" >&2
  exit 1
}

STYLE=$(cat <<'EOF'
.message-render .message-timestamp{opacity:1 !important}
.message-render .user-turn > h2.sr-only:has(> time.message-timestamp){position:static;width:auto;height:auto;margin:0 0 4px 0;padding:0;overflow:visible;clip-path:none;white-space:normal;border-width:0;font-size:0;line-height:0}
.message-render .user-turn > h2.sr-only:has(> time.message-timestamp) > time.message-timestamp{font-size:12px;line-height:16px;margin-inline-start:0}
EOF
)

SCRIPT=$(cat <<'EOF'
(function () {
  try {
    /*pure:start*/
    var TIME = new Intl.DateTimeFormat("ru", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    var DAY = new Intl.DateTimeFormat("ru", { day: "numeric", month: "short" });
    var DAY_YEAR = new Intl.DateTimeFormat("ru", { day: "numeric", month: "short", year: "numeric" });
    var FULL = new Intl.DateTimeFormat("ru", {
      weekday: "long", day: "numeric", month: "long", year: "numeric",
      hour: "2-digit", minute: "2-digit", hourCycle: "h23"
    });
    var REL = new Intl.RelativeTimeFormat("ru", { numeric: "always" });

    function dayStart(d) {
      return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    }

    function pick(parts, type) {
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].type === type) return parts[i].value;
      }
      return "";
    }

    function absolute(d, now) {
      var time = TIME.format(d);
      var days = Math.round((dayStart(now) - dayStart(d)) / 86400000);
      if (days <= 0) return time;
      if (days === 1) return "вчера, " + time;
      var sameYear = d.getFullYear() === now.getFullYear();
      var parts = (sameYear ? DAY : DAY_YEAR).formatToParts(d);
      var text = pick(parts, "day") + " " + pick(parts, "month");
      if (!sameYear) text += " " + pick(parts, "year");
      return text + ", " + time;
    }

    function label(date, now, isLastBot) {
      var d = date.getTime() > now.getTime() ? now : date;
      if (isLastBot) {
        var age = now.getTime() - d.getTime();
        if (age < 300000) {
          if (age < 60000) return "только что";
          return REL.format(-Math.floor(age / 60000), "minute");
        }
      }
      return absolute(d, now);
    }

    function title(date) {
      return FULL.format(date);
    }
    /*pure:end*/

    function setText(el, value) {
      if (el.textContent === value) return;
      var kids = el.childNodes;
      if (kids.length === 1 && kids[0].nodeType === 3) kids[0].nodeValue = value;
      else el.textContent = value;
    }

    function update() {
      try {
        var times = document.querySelectorAll(".message-render time.message-timestamp[datetime]");
        var turns = document.querySelectorAll(".message-render .agent-turn");
        var last = turns.length
          ? turns[turns.length - 1].querySelector("time.message-timestamp[datetime]")
          : null;
        var now = new Date();
        for (var i = 0; i < times.length; i++) {
          var el = times[i];
          var date = new Date(el.getAttribute("datetime"));
          if (isNaN(date.getTime())) continue;
          setText(el, label(date, now, el === last));
          var full = title(date);
          if (el.getAttribute("title") !== full) el.setAttribute("title", full);
        }
      } catch (e) {}
    }

    var pending = false;
    function run() {
      pending = false;
      update();
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
          childList: true, subtree: true, characterData: true
        });
        setInterval(update, 15000);
        update();
      } catch (e) {}
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();
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

# The markup and the styles the patch relies on must still be in the client bundle.
[ -d "$DIST/assets" ] || fail "$DIST/assets not found"
node - "$DIST/assets" <<'EOF' || fail "the client bundle no longer matches what the patch relies on"
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const read = (ext) =>
  fs.readdirSync(dir)
    .filter((n) => n.endsWith(ext))
    .map((n) => fs.readFileSync(path.join(dir, n), "utf8"))
    .join("\n");
const css = read(".css");
const js = read(".js");
const count = (text, pattern) =>
  typeof pattern === "string"
    ? text.split(pattern).length - 1
    : (text.match(new RegExp(pattern.source, "g")) || []).length;
let bad = 0;
const check = (name, text, pattern, exactlyOnce) => {
  const n = count(text, pattern);
  if (exactlyOnce ? n !== 1 : n < 1) {
    console.error("expected " + (exactlyOnce ? "exactly one" : "at least one") + " match, found " + n + ": " + name);
    bad++;
  }
};
// CSS: the rule that hides timestamps until hover (unlayered, inside media queries), and the exact
// .sr-only definition (in @layer utilities; every property of it is undone by the injected style).
// ".sr-only{" also keeps the responsive variant .max-md\:sr-only{ out of the match.
check("CSS rule hiding timestamps",
  css, ".message-render .message-timestamp{opacity:0}", true);
check("CSS .sr-only definition",
  css, ".sr-only{clip-path:inset(50%);white-space:nowrap;border-width:0;width:1px;height:1px;margin:-1px;padding:0;position:absolute;overflow:hidden}", true);
// JS: the timestamp element, its datetime attribute, and the turn containers.
check("timestamp class string",
  js, "message-timestamp text-text-secondary text-xs font-normal", true);
check("time element with a dateTime prop",
  js, /`time`,\{dateTime:[\w$.]+,/, false);
check("message-render class", js, "message-render", false);
check("agent-turn class", js, "agent-turn", false);
// MessageRow lives in a separate chunk. The turn classes are picked by two expressions
// (`isUserSide && "user-turn"`, `!isUserSide && !isSystem && "agent-turn"`), and the user header
// is the h2.sr-only holding [headerPrefix, label, <timestamp component>]; the bot header passes
// className "ms-auto shrink-0 font-normal" to the timestamp component. (The steer-part in another
// chunk is also div.user-turn > h2.sr-only but holds no time: the style does not touch it.)
check("turn class selection (user-turn / agent-turn)",
  js, /[\w$]+&&`user-turn`,![\w$]+&&![\w$]+&&`agent-turn`/, true);
check("user header: h2.sr-only holding the timestamp component",
  js, /\(`h2`,\{className:`sr-only`,children:\[[\w$]+,[\w$]+,\(0,[\w$.]+\)\([\w$]+,\{value:[\w$]+\}\)\]\}\)/, true);
check("bot header: timestamp component with ms-auto",
  js, /\{value:[\w$]+,className:`ms-auto shrink-0 font-normal`\}/, true);
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
[ "$(grep -Fo "$MARKER" "$INDEX" | wc -l)" -eq 2 ] || fail "marker not present exactly twice (style and script) after the patch"
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

echo "patch-timestamps: timestamps always visible, shown on user messages, formatted in $INDEX (.br and .gz regenerated)"
