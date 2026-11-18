# parley

A personal Poe-like service on a VPS: a chat interface with several models, voice input and bots that can reach files and a terminal. The repository holds only configs, no code.

The chat interface is LibreChat, running on one VPS. Login is by password, without two-factor authentication.

- Models over API: Anthropic, Gemini and OpenAI.
- Speech-to-text: OpenAI (`gpt-transcribe`).
- Bots are LibreChat model specs (`modelSpecs` in `librechat.yaml`). Their tools come from two MCP containers: files and a terminal in the clones of two git repositories, the Obsidian vault `notes` and `handoff` (commits and pushes use deploy keys), and a headless browser for reading web pages.

## Architecture

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `librechat` | built from `./librechat` on top of `registry.librechat.ai/librechat-ai/librechat:v0.8.8` | `parley-librechat:3080` on the Caddy network, `127.0.0.1:3080` | chat interface, bots |
| `mongodb` | `mongo:8.0.20` | internal | LibreChat database, no authentication and no ports exposed |
| `tools` | built from `./tools` | internal, `8000` (`/mcp`) | MCP server: DesktopCommander behind supergateway |
| `playwright` | `mcr.microsoft.com/playwright/mcp:v0.0.85` | internal, `8931` (`/mcp`) | MCP server: headless Chromium (Playwright MCP) |

Caddy runs in a container of the selfhost-music compose project and proxies to `parley-librechat:3080` over the shared `CADDY_NETWORK` network (default `selfhost-music_default`). The port on the host's `127.0.0.1` exists only for access through an ssh tunnel.

The `librechat` image is derived from the official one (`librechat/Dockerfile`). It carries two build-time patches. The first is the PWA theme colour: the manifest of LibreChat sets `theme_color` to `#009688`, which paints a green status bar in the Android PWA. The build replaces it with `#171717` (the colour of `<meta name="theme-color">` in `index.html`) and updates the revision of the manifest in the service worker precache; without the second step installed clients keep the old manifest. The build fails if the patterns it patches are not found, so an upgrade of LibreChat that changes these files does not go unnoticed. After the colour changes, an installed PWA picks it up when its service worker updates; to get it at once, remove the PWA from the phone and install it again. The second patch (`librechat/patch-agents.sh`) fixes `@librechat/agents` 4.0.1, which runs tool calls eagerly while the response streams: when the model emitted several Anthropic built-in `web_search` calls in one message, all but the last were executed locally and the message got `Error: Tool web_search not found`. The patch skips Anthropic server-side tool calls (ids starting with `srvtoolu_`) in `createEagerToolExecutionPlan` in `dist/cjs/stream.cjs` and `dist/esm/stream.mjs`, the same check that the regular path in `ToolNode.cjs` already has. It fails the build if the expected line is not found exactly once in each file; after an upgrade, check whether the upstream already fixed this and drop the patch if so.

The `tools` container:

- file operations are limited to `/data` (`/data/notes`, `/data/handoff`);
- the terminal is not limited to that directory: `git commit`, `git pull` and `git push` run through it;
- the terminal can also open an ssh session to the VPS host (`ssh vps`, the user `ubuntu` with passwordless sudo): the bots have full shell access to the host (section 2); this is a deliberate choice of the owner;
- every minute the container runs `git pull --ff-only` in the notes clone (`tools/entrypoint.sh`), so the bots see edits from Obsidian made during a conversation; the pull never commits or pushes and is skipped when the bot has local commits or an uncommitted edit of an incoming file, which the bot resolves with its own `git pull --rebase` (before its first edit and when a push is rejected); a stale `index.lock` left by a killed container is removed on start;
- the DesktopCommander config and logs live in `./data/tools/desktop-commander` and survive container recreation;
- on every start DesktopCommander telemetry is switched off and `allowedDirectories` is set to `/data`;
- supergateway exposes only the file, search and terminal tools of DesktopCommander (`--tools` in `tools/entrypoint.sh`): every model request carries the tool descriptions, so unused tools cost tokens; `set_config_value` is not exposed either (the terminal can still edit the config file);
- `curl` and `pdftotext` (poppler-utils) are installed next to `ripgrep`: web pages and PDFs are downloaded into files and searched there;

The `playwright` container is the official Playwright MCP image (linux/arm64 included) with headless Chromium; the server speaks streamable HTTP on port 8931 and is reached by the bots only through LibreChat. The flags are in `docker-compose.yml`, each with a comment. How a page is read:

1. `browser_navigate` opens the URL. The server runs with `--snapshot-mode none`, so this call and the other actions (`browser_click`, `browser_type`, ...) return only a few lines: the page URL and title.
2. `browser_snapshot` with a `filename` such as `/data/web/<name>.yml` writes the accessibility snapshot of the page to a file and returns only the file path.
3. The bot searches the file in the `tools` terminal (`rg -n -C 5 <text> /data/web/<name>.yml`, then `sed -n '120,180p'`) and reads only the lines it needs. Element references from the snapshot (`ref=e52`) work in `browser_click` and `browser_type`.

`browser_snapshot` without a `filename` still returns the whole snapshot inline (about 90 KB for a long Wikipedia article); no flag prevents it, so the bot rules must forbid it. The cap `maxToolResultChars` then limits the damage to 40,000 characters. `browser_find` (search in the snapshot, with `maxResults` and an optional `filename`) is available as well.

`./data/web` is mounted at the same path `/data/web` in `playwright` and `tools`: a path returned by the browser works in the terminal. The browser may write only there (its working directory and `--output-dir`; other paths are refused, `file:` URLs are blocked). The directory is scratch space: it also receives console logs of the browser, downloaded PDFs and Jina Reader output. When its files exceed 200 MB (`--output-max-size`), the browser deletes the oldest ones after each tool call; no cron job is needed. Files of the `tools` container are root-owned, which is fine for deletion because the directory belongs to the host user; bots keep files directly in `/data/web`, without subdirectories.

The browser has no authentication. It sits on its own `browser` network, shared only with `librechat` (the bots reach it through LibreChat), and is not on the `default` network: it cannot open `tools:8000` (the shell MCP server without authentication) or `mongodb` (the `db` network). It can reach `librechat:3080` and the whole internet (the `browser` network is a regular bridge, not internal; the browser needs the internet). Known remaining reach: the Docker gateway of the host and the cloud metadata service `169.254.169.254` (Oracle; version 1 of its API answers without a token). Like the shell access of the `tools` container, the browser is open to anyone who can talk to a bot with these servers.

Browser state lives only as long as one MCP session. `--isolated` keeps the profile in memory (cookies, logins, open tabs); each MCP session gets its own isolated context. In `librechat.yaml` the `playwright` server has a `requestHeaders` entry with `{{LIBRECHAT_BODY_CONVERSATIONID}}`; it is not used by the server, its purpose is to make LibreChat open a separate MCP session for each chat request instead of one shared connection for all chats (otherwise all chats would share one browser tab and concurrent chats would overwrite each other's page). Within one turn (one request, including all its tool calls) the page stays open; the session is closed when the turn ends, so the next turn starts with an empty browser and the bot opens the page again. Snapshot files in `/data/web` remain and can be searched in the next turn. Chromium takes about 300 MB when idle and more on heavy pages: the container is limited to 3 GB (`mem_limit`) and has a 1 GB `/dev/shm`.

## Bots

A bot is an item of `modelSpecs` in `librechat.yaml`: a model, a label, a description, the connected `tools` MCP server and a short instruction (`promptPrefix`). The bot's actual prompt is not stored in this repository. At the start of a conversation the instruction makes the bot run `git pull --rebase` in the vault clone, then read two files from the vault: the shared bot rules and the file of its own role (a `text` block in each). Those texts become the bot's system prompt for the rest of the conversation. Editing a prompt in Obsidian therefore takes effect without a redeploy: it is enough for the change to reach the vault clone on the VPS.

Bots:

| Bot | Provider | Model |
| --- | --- | --- |
| `Erudite-assistant-Opus` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Erudite-assistant-Carbon` | Google | `gemini-4-carbon`, thinking level `high`, native web search (Google Search grounding) |
| `Erudite-assistant-Hydrogen` | Google | `gemini-4-hydrogen`, thinking level `high`, native web search (Google Search grounding) |
| `Doctor` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `BackEnder` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Backender-villain` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Insightful-genius` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Avtor` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Brilliant-Sage` | Google | `gemini-3.8-flash` |
| `English-friend` | OpenAI | `gpt-5.4-mini` |
| `Engspeech-fixer` | OpenAI | `gpt-5.4`, reasoning effort `high`, Responses API |
| `WingswingMan` | OpenAI | `gpt-5.4-mini` |

Each bot reads the role file with its own name from the `prompts` folder of the vault (`Doctor.md`, `BackEnder.md`, ...; the Erudite variants share `Erudite-assistant.md`).

All Erudite-assistant variants read the same role file. Web search is the provider's native tool (`web_search: true` in the preset), not LibreChat's own web search, which would replace it and is not configured. `interface.webSearch` is nevertheless `true`: it grants the roles the web search permission, and without it LibreChat silently strips the native tool too. The web search button in the chat starts LibreChat's own search; leave it off. LibreChat 0.8.8 has no price or context window data for `gemini-4-carbon` and `gemini-4-hydrogen`: the preset sets `maxContextTokens` explicitly (otherwise the window becomes 1,024 tokens), and spending on them is counted at the generic "gemini" rate, cached input tokens included at the full input price. The sources of the native search are not shown in the UI.

All bots also get the `playwright` MCP server (`mcpServers` of each spec). The rules for reading the web (search first, then Jina Reader, the browser when Jina fails or the page needs interaction, PDFs through `curl` and `pdftotext`) live in the shared bot rules in the vault, not here.

`endpoints.all.maxToolResultChars` in `librechat.yaml` caps a single tool result at 40,000 characters. A longer result is cut: its head and tail are kept and the middle is replaced by a `[truncated: N chars exceeded 40000 limit]` notice. Without the cap one read of a web page returned about 206k tokens, which was resent with every later request of the conversation.

`enforce` is `false` and `interface.modelSelect` is `true`: models outside the specs stay selectable. LibreChat 0.8.8 talks to `gpt-6-luna` through the Responses API, so its tool calls work with any reasoning effort. `gpt-5.4` and `gpt-5.4-mini` run on Chat Completions by default, and there they do not reason (the default effort is `none`). With any other reasoning effort, gpt-5.4 rejects function tools in Chat Completions with a 400 ("use /v1/responses or set reasoning_effort to 'none'"), so `Engspeech-fixer` sets `reasoning_effort: high` together with `useResponsesApi: true`; a bot that needs reasoning on these models does the same.

Every bot sets `maxContextTokens: 550000`: LibreChat prunes older messages beyond it, which keeps a long conversation from being re-sent whole (after a pause longer than the prompt cache lifetime, the whole history is written to the cache again at the full price). The `gpt-5.4-mini` bots are the exception: the model's window is 400k, so LibreChat's own limit for it is kept. The cap does not limit the server-side loop of Anthropic's web search inside one request.

A new bot is a new `modelSpecs` item in `librechat.yaml` (with its role file in the vault), then:

```bash
docker compose up -d --force-recreate librechat
```

## Deployment on the VPS

API keys exist only in `.env` on the VPS. Never print secret values to the terminal or chat.

### 1. Directories and permissions

The `librechat`, `mongodb` and `playwright` containers run as the `UID:GID` user from `.env` and write to the `./data/...` directories (`playwright` to `./data/web`, which the `tools` container also mounts). Create the directories in advance as that same user:

```bash
sudo mkdir -p /opt/parley && sudo chown "$USER": /opt/parley
git clone <parley repository URL> /opt/parley
cd /opt/parley
mkdir -p data/mongo data/tools/desktop-commander data/web \
  data/librechat/images data/librechat/uploads data/librechat/logs data/librechat/data
id -u; id -g
```

Put the values of `id -u` and `id -g` into `UID` and `GID` in `.env`. Both are required: compose refuses to start without them (no default), so a container never runs as an unintended user.

### 2. Deploy keys and the notes and handoff clones

Each repository gets its own key with write access. The key directory lives outside the parley repository (`TOOLS_SSH_DIR`):

```bash
sudo mkdir -p /opt/parley-ssh /opt/parley-data
sudo chown "$USER": /opt/parley-ssh /opt/parley-data
chmod 700 /opt/parley-ssh
ssh-keygen -t ed25519 -N '' -C parley-notes -f /opt/parley-ssh/notes
ssh-keygen -t ed25519 -N '' -C parley-handoff -f /opt/parley-ssh/handoff
ssh-keyscan github.com > /opt/parley-ssh/known_hosts
```

Add the public keys (`notes.pub`, `handoff.pub`) on GitHub: repository, Settings, Deploy keys, Add deploy key, enable Allow write access.

The file `/opt/parley-ssh/config` with aliases; the paths are inside the container:

```text
Host github-notes
  HostName github.com
  User git
  IdentityFile /root/.ssh/notes
  IdentitiesOnly yes
  UserKnownHostsFile /root/.ssh/known_hosts
  StrictHostKeyChecking yes

Host github-handoff
  HostName github.com
  User git
  IdentityFile /root/.ssh/handoff
  IdentitiesOnly yes
  UserKnownHostsFile /root/.ssh/known_hosts
  StrictHostKeyChecking yes
```

Shell access to the VPS host (done before the key directory is handed to root below). The `tools` container reaches the host through the name `host.docker.internal` (`extra_hosts` in `docker-compose.yml`). **This gives the bots full shell access to the VPS host as the user `ubuntu` with passwordless sudo, i.e. root on the host. It is a deliberate choice of the owner; anyone who can talk to a bot with the `tools` server can use it.**

Create a key pair `host`, allow its public key on the host and pin the host key, so that ssh does not ask anything and does not accept another host under this name. The host key is taken from the host's own public key file and written under the name the container uses (`ssh-keyscan` is not suitable: it would scan the name from the host, not from the container network):

```bash
ssh-keygen -t ed25519 -N '' -C parley-host -f /opt/parley-ssh/host
cat /opt/parley-ssh/host.pub >> /home/ubuntu/.ssh/authorized_keys
echo "host.docker.internal $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" >> /opt/parley-ssh/known_hosts
```

On an existing installation the directory already belongs to root, so the same steps run with sudo (then add the `Host vps` entry below to the config with `sudo` as well and recreate the container: `docker compose up -d --force-recreate tools`):

```bash
sudo ssh-keygen -t ed25519 -N '' -C parley-host -f /opt/parley-ssh/host
sudo cat /opt/parley-ssh/host.pub >> /home/ubuntu/.ssh/authorized_keys
echo "host.docker.internal $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" | sudo tee -a /opt/parley-ssh/known_hosts >/dev/null
```

The entry in `/opt/parley-ssh/config`:

```text
Host vps
  HostName host.docker.internal
  User ubuntu
  IdentityFile /root/.ssh/host
  IdentitiesOnly yes
  UserKnownHostsFile /root/.ssh/known_hosts
  StrictHostKeyChecking yes
```

If the connection from the container times out, the host firewall blocks port 22 from the Docker network; allow it there. Check after the start (section 4): `docker compose exec tools ssh vps true`.

The clones are made from the host with the same keys, then the remote is switched to the aliases (inside the container ssh uses the config):

```bash
GIT_SSH_COMMAND='ssh -i /opt/parley-ssh/notes -o IdentitiesOnly=yes -o UserKnownHostsFile=/opt/parley-ssh/known_hosts' \
  git clone git@github.com:roman-redl/notes.git /opt/parley-data/notes
git -C /opt/parley-data/notes remote set-url origin git@github-notes:roman-redl/notes.git

GIT_SSH_COMMAND='ssh -i /opt/parley-ssh/handoff -o IdentitiesOnly=yes -o UserKnownHostsFile=/opt/parley-ssh/known_hosts' \
  git clone git@github.com:roman-redl/handoff.git /opt/parley-data/handoff
git -C /opt/parley-data/handoff remote set-url origin git@github-handoff:roman-redl/handoff.git
```

The container runs as root, and ssh refuses to read a config and keys owned by another user. So the key directory is handed to root:

```bash
sudo chown -R root:root /opt/parley-ssh
sudo chmod 600 /opt/parley-ssh/notes /opt/parley-ssh/handoff /opt/parley-ssh/host /opt/parley-ssh/config
```

The clones stay owned by the regular user: root inside the container can write to them, and git in the container is configured to accept a directory owned by someone else.

### 3. The .env file

```bash
cp .env.example .env
chmod 600 .env
```

What to fill in:

- `DOMAIN_CLIENT`, `DOMAIN_SERVER` — the public address of LibreChat.
- `CREDS_KEY` (`openssl rand -hex 32`), `CREDS_IV` (`openssl rand -hex 16`), `JWT_SECRET`, `JWT_REFRESH_SECRET` (all `openssl rand -hex 32`) — generated on the VPS.
- `ALLOW_REGISTRATION` stays `false`; it is opened only for the first login (section 5).
- `NOTES_DIR=/opt/parley-data/notes`, `HANDOFF_DIR=/opt/parley-data/handoff`, `TOOLS_SSH_DIR=/opt/parley-ssh`.
- `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` — the signature of the bots' commits.
- `UID`, `GID` — from step 1.
- `ENDPOINTS`, `ANTHROPIC_MODELS`, `GOOGLE_MODELS`, `OPENAI_MODELS` — already set in the template.

The provider keys are already on the VPS and are moved into `.env` without printing them. The Gemini key lies in `~/.config/parley/secrets.env` (a `GOOGLE_KEY=...` line); remove the empty `GOOGLE_KEY=` line from `.env`, append the real one and delete the temporary file:

```bash
grep -q '^GOOGLE_KEY=.' ~/.config/parley/secrets.env \
  && sed -i '/^GOOGLE_KEY=/d' .env \
  && grep '^GOOGLE_KEY=.' ~/.config/parley/secrets.env >> .env \
  && grep -q '^GOOGLE_KEY=.' .env \
  && rm ~/.config/parley/secrets.env \
  && echo "GOOGLE_KEY moved"
```

The temporary file is deleted only after the key is in `.env`; if the command prints nothing, check the file format (`GOOGLE_KEY=...` without `export`).

`ANTHROPIC_API_KEY` is taken the same way from the `.env` of erudit-bot on the same VPS, and its `OPENAI_API_KEY` (an OpenAI project without data sharing, used only for speech-to-text) becomes `OPENAI_STT_API_KEY` here:

```bash
SRC=<erudit-bot dir>/.env
[ "$(grep -cE '^(ANTHROPIC_API_KEY|OPENAI_API_KEY)=.' "$SRC")" = 2 ] \
  && sed -i '/^ANTHROPIC_API_KEY=/d;/^OPENAI_STT_API_KEY=/d' .env \
  && grep -E '^ANTHROPIC_API_KEY=.' "$SRC" >> .env \
  && grep -E '^OPENAI_API_KEY=.' "$SRC" | sed 's/^OPENAI_API_KEY=/OPENAI_STT_API_KEY=/' >> .env \
  && echo "keys moved"
```

`OPENAI_API_KEY` is the key of a separate OpenAI project with data sharing turned on (it gets free daily tokens), used only for the OpenAI chat bots; it is written into `.env` by hand.

Both commands replace the existing lines, so running them again does not create duplicates. Check without printing the values — each line must output `1`:

```bash
for k in ANTHROPIC_API_KEY OPENAI_API_KEY OPENAI_STT_API_KEY GOOGLE_KEY; do echo "$k $(grep -c "^$k=." .env)"; done
```

Speech-to-text and the chat use different keys: data sharing must not cover voice recordings.

### 4. Start

```bash
docker compose up -d --build
docker compose ps
docker compose logs tools
```

The `tools` and `playwright` containers must reach the `healthy` state; `librechat` waits for both. The first start pulls the Playwright image (about 430 MB).

### 5. First login

Any user registered in LibreChat gets bots with a terminal in the `tools` container, so registration is opened only while creating your own account, only through an ssh tunnel and before the Caddy route exists.

1. Set `ALLOW_REGISTRATION=true` in `.env`, then run `docker compose up -d --force-recreate librechat`.
2. From your computer open the tunnel `ssh -L 3080:127.0.0.1:3080 <VPS>` and register in LibreChat at `http://localhost:3080`.
3. Set `ALLOW_REGISTRATION=false` in `.env` again, then run `docker compose up -d --force-recreate librechat`.
4. Only after that does the administrator add the Caddy route (section 7).

### 6. MCP connection

LibreChat connects `tools` and `playwright` through `librechat.yaml` (the `mcpServers` block) and the bots enable them through `mcpServers` in their model specs; no manual steps are needed. The addresses `tools:8000` and `playwright:8931` are allowed in `mcpSettings.allowedAddresses`: without it LibreChat blocks requests to private addresses. The Playwright server itself also checks the `Host` header and accepts only `playwright:8931` (`--allowed-hosts`); if the service is renamed or the port changes, change both places and the flags.

### 7. Caddy route

Done by the administrator in the selfhost-music Caddyfile: `reverse_proxy parley-librechat:3080`. The `CADDY_NETWORK` network must exist before `docker compose up` of parley; find its name with `docker network ls` on the VPS.

## Updating and redeploying

```bash
cd /opt/parley
git pull
mkdir -p data/web
docker compose up -d --build --remove-orphans
```

`mkdir -p data/web` matters on an install that predates the `playwright` service: the directory must be created by the deploying user, otherwise Docker creates it as root and the browser, which runs as `UID:GID`, cannot write there. If Docker has already created it as root: `sudo chown "$(id -u):$(id -g)" data/web`.

`--remove-orphans` stops and removes containers of services deleted from `docker-compose.yml`.

`librechat.yaml` is bind-mounted as a single file: compose does not notice its changes, and `git pull` replaces the file (new inode), so the running container keeps the old version. After a change to `librechat.yaml` recreate LibreChat explicitly:

```bash
docker compose up -d --force-recreate librechat
```

Versions are pinned: LibreChat in `librechat/Dockerfile` (the `FROM` tag), MongoDB and the Playwright MCP image in `docker-compose.yml`, the npm packages in `tools/Dockerfile`; changing them is a separate, deliberate change. A LibreChat upgrade is a change of the `FROM` tag; the build fails if the files patched by `librechat/patch-pwa.sh` (PWA) or `librechat/patch-agents.sh` (`@librechat/agents` stream code) changed, and then the script is adjusted to the new files or dropped if the upstream fixed the problem.

Logs of all containers are rotated by Docker (3 files of 10 MB each per container). The `tools` container does not log tool calls: supergateway runs with `--logLevel none`, otherwise it would write every JSON-RPC message, including the contents of the notes, into the log.

## Adding a model

Append the model name to `ANTHROPIC_MODELS`, `GOOGLE_MODELS` or `OPENAI_MODELS` in `.env` on the VPS, then recreate the container: `docker compose up -d --force-recreate librechat`. A bot's model must stay in the matching `*_MODELS` list: otherwise LibreChat silently substitutes the first model of the list. The models of the bots above need these entries: `gpt-5.4` and `gpt-5.4-mini` in `OPENAI_MODELS`, `gemini-4-carbon` and `gemini-4-hydrogen` in `GOOGLE_MODELS` (the `.env.example` template has them; an existing `.env` on the VPS is updated by hand). A model unknown to the installed LibreChat version needs `maxContextTokens` in the bot preset, as in `Erudite-assistant-Carbon`; otherwise the context window falls back to 1,024 tokens.
