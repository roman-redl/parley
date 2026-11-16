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
# --tools: only these DesktopCommander tools are listed and callable. The tool descriptions
# are sent with every model request, and DesktopCommander has no setting to hide tools.
# Left out: config (get_config, set_config_value), PDF generation, usage stats and feedback,
# search bookkeeping (list_searches, stop_search; finished searches are dropped after 5 minutes),
# OS process management (list_processes, kill_process). list_sessions stays: the container has
# no ps, and it is the only way to find a terminal session whose PID the bot has lost.
# The kept descriptions of start_search and write_file still mention stop_search and write_pdf;
# a call to them fails with "Unknown tool", which costs one round trip and nothing else.
exec supergateway \
  --logLevel none \
  --stdio "desktop-commander --no-onboarding" \
  --outputTransport streamableHttp \
  --stateful \
  --port 8000 \
  --streamableHttpPath /mcp \
  --healthEndpoint /healthz \
  --tools read_file \
  --tools read_multiple_files \
  --tools write_file \
  --tools edit_block \
  --tools create_directory \
  --tools list_directory \
  --tools move_file \
  --tools get_file_info \
  --tools start_search \
  --tools get_more_search_results \
  --tools start_process \
  --tools read_process_output \
  --tools interact_with_process \
  --tools force_terminate \
  --tools list_sessions
