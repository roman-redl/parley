#!/bin/sh
# Entrypoint of the tools container: prepares git and the config, then runs supergateway.
set -eu

# The clones are mounted from the host and owned by another user; without this
# git refuses to work ("dubious ownership").
git config --global safe.directory '*'

# git reads GIT_AUTHOR_*/GIT_COMMITTER_* from the environment itself; they are also
# written to the config so that processes with a cleared environment keep the identity.
[ -n "${GIT_AUTHOR_NAME:-}" ] && git config --global user.name "$GIT_AUTHOR_NAME"
[ -n "${GIT_AUTHOR_EMAIL:-}" ] && git config --global user.email "$GIT_AUTHOR_EMAIL"

# compose passes unset variables as empty strings, and an empty GIT_* variable
# overrides user.name/user.email and makes commits fail.
for v in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
  eval "[ -n \"\${$v:-}\" ] || unset $v"
done

DC_DIST="$(npm root -g)/@wonderwhy-er/desktop-commander/dist"
node /opt/parley/init-config.mjs "$DC_DIST"

# --stateful mode: DesktopCommander terminal sessions (start_process,
# read_process_output) live in a child process; without it every request would
# start a new process and sessions would be lost between calls.
# --logLevel none: supergateway otherwise logs every JSON-RPC message, including the full
# tool outputs (that is, the contents of the notes) into the container log.
exec supergateway \
  --logLevel none \
  --stdio "desktop-commander --no-onboarding" \
  --outputTransport streamableHttp \
  --stateful \
  --port 8000 \
  --streamableHttpPath /mcp \
  --healthEndpoint /healthz
