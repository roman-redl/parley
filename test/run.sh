#!/bin/bash
# Driver of the parley test harness: runs one chat turn against a bot from a workstation over ssh.
#   ./test/run.sh <spec | agent_...> <text | @localfile> [--conv ID --parent ID] [--image localfile]
#                 [--file localfile [--file-mode provider|text]] [--upload-only] [--dump]
#   ./test/run.sh --report <conversationId>
#   ./test/run.sh --steps <conversationId>
# Environment:
#   PARLEY_SSH      ssh destination of the VPS (a ~/.ssh/config alias or user@host); required
#   PARLEY_SSH_KEY  optional ssh key, passed as -i
#   PARLEY_DIR      directory of the compose project on the VPS (default /opt/parley)
#   PARLEY_TAG      isolates the staging files, so a second run can go in parallel with another one
# <spec> is the name of a modelSpecs item; a name starting with agent_ chats with that saved agent
# directly. Runs chat.mjs inside the librechat container; the test user's credentials
# (PARLEY_TEST_EMAIL, PARLEY_TEST_PASSWORD) are read from .env on the VPS only and never printed.
# After a chat turn the report of the conversation is printed (report.js).
# --report prints the report of an existing conversation: tool calls, subagent calls, final text,
#   cost by context x model. --steps dumps the last reply part by part (steps.js).
# --conv/--parent continue a conversation (--parent is the previous responseMessageId).
# --image attaches an image. --file attaches a document as the web client does; --file-mode
#   provider (default): the model gets the file itself (PDF -> base64 document block on Anthropic);
#   text: "Upload as Text", the extracted text goes into the prompt.
# --upload-only uploads the --file/--image and prints the upload response; no message is sent
#   (<text> is still required, e.g. "-").
# --dump keeps the raw SSE stream in ./last-sse.txt.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n 2,24p "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ -n "${PARLEY_SSH:-}" ] || { echo "PARLEY_SSH is not set: ssh destination of the VPS (an ~/.ssh/config alias or user@host)" >&2; exit 2; }
SSH=(ssh); SCP=(scp -q)
if [ -n "${PARLEY_SSH_KEY:-}" ]; then SSH+=(-i "$PARLEY_SSH_KEY"); SCP+=(-i "$PARLEY_SSH_KEY"); fi
SSH+=("$PARLEY_SSH")
HOST="$PARLEY_SSH"
PDIR="${PARLEY_DIR:-/opt/parley}"
[[ "$PDIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "bad PARLEY_DIR: $PDIR" >&2; exit 2; }

ONLY_MODE=""; ONLY_ID=""; SPEC=""; TEXT=""; CONV=""; PARENT=""; IMAGE=""; DUMP=0
FILE=""; FILE_MODE=""; UPLOAD_ONLY=0
case "${1:-}" in
  --report|--steps)
    [ $# -eq 2 ] || usage
    ONLY_MODE="${1#--}"; ONLY_ID="$2" ;;
  *)
    [ $# -ge 2 ] || usage
    SPEC="$1"; TEXT="$2"; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --conv)   CONV="${2:?}"; shift 2 ;;
        --parent) PARENT="${2:?}"; shift 2 ;;
        --image)  IMAGE="${2:?}"; shift 2 ;;
        --dump)   DUMP=1; shift ;;
        --file)      FILE="${2:?}"; shift 2 ;;
        --file-mode) FILE_MODE="${2:?}"; shift 2 ;;
        --upload-only) UPLOAD_ONLY=1; shift ;;
        *) usage ;;
      esac
    done ;;
esac
# only simple tokens are interpolated into remote commands; free text always travels as a file
re='^[A-Za-z0-9._-]+$'
for v in "$ONLY_ID" "$SPEC" "$CONV" "$PARENT"; do
  [ -z "$v" ] || [[ "$v" =~ $re ]] || { echo "bad argument: $v" >&2; exit 2; }
done
TAG="${PARLEY_TAG:-}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]*$ ]] || { echo "bad PARLEY_TAG: $TAG" >&2; exit 2; }
[ -z "$TAG" ] || TAG="-$TAG"
RDIR=/tmp/parley-run$TAG  # staging dir on the VPS
case "$FILE_MODE" in ""|provider|text) ;; *) echo "bad --file-mode: $FILE_MODE (provider|text)" >&2; exit 2 ;; esac
[ -z "$FILE_MODE" ] || [ -n "$FILE" ] || { echo "--file-mode requires --file" >&2; exit 2; }
[ -z "$FILE" ] || [ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }
[ "$UPLOAD_ONLY" = 0 ] || [ -n "$FILE$IMAGE" ] || { echo "--upload-only requires --file or --image" >&2; exit 2; }

"${SSH[@]}" "mkdir -p $RDIR"
"${SCP[@]}" "$HERE/report.js" "$HERE/steps.js" "$HOST:$RDIR/"

if [ -z "$ONLY_MODE" ]; then
  "${SCP[@]}" "$HERE/chat.mjs" "$HOST:$RDIR/chat.mjs"
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  if [ "${TEXT#@}" != "$TEXT" ]; then cp "${TEXT#@}" "$TMP" || exit 2; else printf '%s' "$TEXT" > "$TMP"; fi
  "${SCP[@]}" "$TMP" "$HOST:$RDIR/text.txt"
  IMG_EXT=""
  if [ -n "$IMAGE" ]; then
    IMG_EXT=".${IMAGE##*.}"
    "${SCP[@]}" "$IMAGE" "$HOST:$RDIR/image$IMG_EXT"
  fi
  FILE_EXT=""
  if [ -n "$FILE" ]; then
    # the file travels under a neutral name; its real name (any characters) travels as a text file
    FILE_EXT=".$(basename "$FILE" | sed -n 's/.*\.\([A-Za-z0-9]\{1,8\}\)$/\1/p')"
    [ "$FILE_EXT" != . ] || FILE_EXT=".bin"
    printf '%s' "$(basename "$FILE")" > "$TMP.name"
    "${SCP[@]}" "$FILE" "$HOST:$RDIR/file$FILE_EXT"
    "${SCP[@]}" "$TMP.name" "$HOST:$RDIR/file-name.txt"
    rm -f "$TMP.name"
  fi
fi

# Remote part. Quoted heredoc: nothing is expanded locally. No `set -x` anywhere (creds in env).
REMOTE=$(cat <<'EOS'
PDIR=$1; MODE=$2; TAG=$3; shift 3
cd "$PDIR" || exit 1
[ "$TAG" = - ] && TAG=
D=/tmp/parley-run$TAG
run_mongosh() { # $1 = script (report|steps), $2 = conversation id
  # stdin would put mongosh into REPL mode (breaks on blank lines), so run a file inside the container
  { echo "const CONV='$2';"; cat $D/$1.js; } > $D/$1-run.js
  docker compose cp $D/$1-run.js mongodb:/tmp/$1-run$TAG.js >/dev/null 2>&1 </dev/null
  docker compose exec -T mongodb mongosh --quiet LibreChat /tmp/$1-run$TAG.js </dev/null
}
if [ "$MODE" = report ] || [ "$MODE" = steps ]; then run_mongosh "$MODE" "$1"; exit $?; fi

SPEC=$1; CONV=$2; PARENT=$3; IMG_EXT=$4; DUMP=$5; FILE_EXT=$6; FILE_MODE=$7; UPLOAD_ONLY=$8
# "-" is the placeholder for an empty argument (ssh drops empty args)
[ "$CONV" = - ] && CONV=; [ "$PARENT" = - ] && PARENT=; [ "$IMG_EXT" = - ] && IMG_EXT=
[ "$FILE_EXT" = - ] && FILE_EXT=; [ "$FILE_MODE" = - ] && FILE_MODE=
export T_EMAIL=$(grep ^PARLEY_TEST_EMAIL= .env | cut -d= -f2-)
export T_PASS=$(grep ^PARLEY_TEST_PASSWORD= .env | cut -d= -f2-)
docker compose cp $D/chat.mjs librechat:/tmp/chat$TAG.mjs >/dev/null 2>&1 </dev/null
docker compose cp $D/text.txt librechat:/tmp/chat-text$TAG.txt >/dev/null 2>&1 </dev/null
A=(--spec "$SPEC" --text-file /tmp/chat-text$TAG.txt)
[ -n "$CONV" ] && A+=(--conv "$CONV" --parent "$PARENT")
if [ -n "$IMG_EXT" ]; then
  docker compose cp "$D/image$IMG_EXT" "librechat:/tmp/chat-image$TAG$IMG_EXT" >/dev/null 2>&1 </dev/null
  A+=(--image "/tmp/chat-image$TAG$IMG_EXT")
fi
if [ -n "$FILE_EXT" ]; then
  docker compose cp "$D/file$FILE_EXT" "librechat:/tmp/chat-file$TAG$FILE_EXT" >/dev/null 2>&1 </dev/null
  A+=(--file "/tmp/chat-file$TAG$FILE_EXT" --file-name "$(cat $D/file-name.txt)")
  [ -n "$FILE_MODE" ] && A+=(--file-mode "$FILE_MODE")
fi
[ "$UPLOAD_ONLY" = 1 ] && A+=(--upload-only)
[ "$DUMP" = 1 ] && A+=(--dump /tmp/chat-sse$TAG.txt)

docker compose exec -T -e T_EMAIL -e T_PASS librechat node /tmp/chat$TAG.mjs "${A[@]}" >$D/out.json 2>$D/err.txt </dev/null
RC=$?
cat $D/err.txt >&2
echo "== result (exit $RC) =="
cat $D/out.json
if [ "$DUMP" = 1 ]; then docker compose cp librechat:/tmp/chat-sse$TAG.txt $D/sse.txt >/dev/null 2>&1 </dev/null; fi
ID=$(sed -n 's/.*"conversationId":"\([^"]*\)".*/\1/p' $D/out.json | head -1)
[ -z "$ID" ] && ID=$(sed -n 's/^conv=\([^ ]*\).*/\1/p' $D/err.txt | head -1)
if [ -n "$ID" ]; then echo; echo "== report =="; run_mongosh report "$ID"; fi
exit $RC
EOS
)

if [ -n "$ONLY_MODE" ]; then
  "${SSH[@]}" bash -s -- "$PDIR" "$ONLY_MODE" "${TAG:--}" "$ONLY_ID" <<<"$REMOTE"
  exit $?
fi
"${SSH[@]}" bash -s -- "$PDIR" run "${TAG:--}" "$SPEC" "${CONV:--}" "${PARENT:--}" "${IMG_EXT:--}" "$DUMP" "${FILE_EXT:--}" "${FILE_MODE:--}" "$UPLOAD_ONLY" <<<"$REMOTE"
RC=$?
[ "$DUMP" = 1 ] && "${SCP[@]}" "$HOST:$RDIR/sse.txt" "$HERE/last-sse.txt" 2>/dev/null
exit $RC
