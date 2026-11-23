# parley

A personal Poe-like service on a VPS: a chat interface with several models, voice input and bots that can reach files and a terminal. The repository holds only configs, no code.

The chat interface is LibreChat, running on one VPS. Login is by password, without two-factor authentication.

- Models over API: Anthropic, Gemini and OpenAI.
- Speech-to-text: OpenAI (`gpt-transcribe`).
- Bots are LibreChat model specs (`modelSpecs` in `librechat.yaml`). Their tools come from two MCP containers: files and a terminal in the clones of two git repositories, the Obsidian vault `notes` and `handoff` (commits and pushes use deploy keys), and a headless browser for reading web pages.

## Architecture

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `librechat` | built from `./librechat` on top of `registry.librechat.ai/librechat-ai/librechat:v0.8.9` | `parley-librechat:3080` on the Caddy network, `127.0.0.1:3080` | chat interface, bots |
| `mongodb` | `mongo:8.0.20` | internal | LibreChat database, no authentication and no ports exposed |
| `tools` | built from `./tools` | internal, `8000` (`/mcp`) | MCP server: DesktopCommander behind supergateway |
| `playwright` | `mcr.microsoft.com/playwright/mcp:v0.0.85` | internal, `8931` (`/mcp`) | MCP server: headless Chromium (Playwright MCP) |

Caddy runs in a container of the selfhost-music compose project and proxies to `parley-librechat:3080` over the shared `CADDY_NETWORK` network (default `selfhost-music_default`). The port on the host's `127.0.0.1` exists only for access through an ssh tunnel.

The `librechat` image is derived from the official one (`librechat/Dockerfile`) and carries nine build-time patches, one script per patch in `librechat/`:

| Script | What it changes (file in the image) | Why | Upstream / when to drop |
| --- | --- | --- | --- |
| `patch-pwa.sh` | `client/dist/manifest.webmanifest`, `sw.js` | PWA status bar colour `#171717` (the colour of `<meta name="theme-color">`) instead of the green `#009688`; the manifest revision in the service worker precache is updated too, otherwise installed clients keep the old manifest. An installed PWA picks the colour up when its service worker updates; to get it at once, remove the PWA from the phone and install it again | Own setting, not a bug |
| `patch-shift.sh` | `client/dist/index.html` (and the precompressed `.br`, `.gz`) | Holding Shift no longer shows the instant Archive and Delete buttons on the active chat (Delete acted without confirmation, and typing a capital letter flashed the buttons); both stay in the "..." menu. An inline script stops the bare Shift `keydown`; capitals, Shift+Enter and Shift shortcuts are unaffected | Own setting |
| `patch-timestamps.sh` | `client/dist/index.html` (and the precompressed `.br`, `.gz`) | Message timestamps are always visible instead of only on hover, and the timestamp of a user message, which the client renders screen-reader-only, is shown above the bubble on the right. The text is rewritten in Russian, in the local time zone, 24-hour clock: `14:35`, `вчера, 14:35`, `18 нояб., 14:35`, `18 нояб. 2025, 14:35` (the client's "10 минут назад" is gone); the `title` holds the full date and time. The timestamp of the last bot message reads `только что` and `N минут назад` while it is under 5 minutes old. An inline style and script do it; a MutationObserver and a 15 s timer keep it applied when React re-renders. The build checks the CSS rules and the markup it relies on | Own setting |
| `patch-images.sh` | `api/server/services/Files/images/resize.js` | Uploads are scaled down (never up) to at most 2576 px on the long edge and 3.7 MP, with EXIF orientation taken into account (was 768 px on the short side: a portrait photo came out at 432×768 to 576×768 and fine print became unreadable). The result is re-encoded to `imageOutputType` from `librechat.yaml`, `webp`: as PNG such a photo weighs 9-11 MB, above the 5 MB per image that LibreChat lets through to Anthropic | Check in a new LibreChat version |
| `patch-tool-images-run.sh` | `@librechat/agents` `dist/{cjs,esm}/messages/core.*` (`projectAnthropicArtifactContent`), `graphs/Graph.*` (`projectServingArtifacts` and the guard before it) | Tool images (Playwright screenshots) stay visible to Anthropic models for the rest of the reply, not just on the next step: a model that read figures from a screenshot no longer sees a bare file path on later steps and no longer concludes that it never saw the image. Only the images of the last 10 tool results are kept (Anthropic caps every image at 2000×2000 px once a request has more than 20 images, and a smaller set makes the fallback to a request without images rarer). Only the current reply is affected (earlier turns are rebuilt from the database without images). Google and OpenAI keep the upstream behaviour on purpose: the image is visible on the next call only, and a step-budget hook message after the tool results hides it | Own change; upstream unchanged in `@librechat/agents` 4.2.7 (the version of LibreChat 0.8.9) and as of 4.2.12 (#677, still open, covers only the image size budget); re-check on every upgrade |
| `patch-gemini-order.sh` | `@librechat/agents` `dist/{cjs,esm}/llm/google/utils/common.*` (the converter of one message to Gemini parts) | Gemini function calls keep their position when a turn is replayed. With Google Search grounding plus function declarations the model sometimes answers one turn as `toolCall` (server-side search), `functionCall`(s), `toolResponse`; exact replay is off for turns with server-side tool parts, and the fallback converter moved every function call behind the `toolResponse`, so Google rejected the next step with `400 Function call is missing a thought_signature in functionCall parts` (signatures are validated by position). Each rebuilt call now takes the place of its functionCall part; calls without a part are appended at the end as before. Intermittent, because the order of the parts is the model's choice | Reported upstream as LibreChat-AI/agents#725, fix proposed in LibreChat-AI/agents#726 (open); drop the patch after upgrading to a LibreChat whose `@librechat/agents` includes it |
| `patch-websearch.sh` | `packages/api/dist/index.cjs` (the Anthropic web search tool definition) | Anthropic native web search uses `web_search_20260318` instead of `web_search_20250305` (dynamic filtering, available since `web_search_20260209`; 20260318 only adds the unused `response_inclusion` parameter): Claude filters the search results with code execution before they enter the context, which cuts input tokens several times on questions with many searches (a six-search question: 224k input tokens with the old version, 37-41k with the new one). LibreChat hardcodes the old type; the patch replaces that one occurrence (the other one is a doc comment). The new version needs no extra tool parameter and no beta header. Needs `patch-agents-servertools.sh` and `patch-anthropic-container.sh`: without them a later request of a turn with a search fails with 400 | LibreChat issue #18222 (the tool version is not configurable), PR LibreChat-AI/LibreChat#18707 (open) makes it configurable; drop the patch after upgrading to a LibreChat that has it (then set `endpoints.anthropic.webSearchToolVersion` in `librechat.yaml`) or uses the newer version itself |
| `patch-agents-servertools.sh` | `@librechat/agents` `dist/{cjs,esm}/llm/anthropic/utils/message_inputs.*` (`_formatContent`), `message_outputs.*` (`_makeMessageChunkFromAnthropicEvent`), `messages/core.*` (`modifyContent`) | With `web_search_20260209` and later the model calls `code_execution` and the nested `web_search` calls carry `caller`. The agents library dropped the `code_execution_tool_result` block (stream parser and replay) and stripped `caller` from `server_tool_use` and `web_search_tool_result`, so the request that continues the same assistant message (after a client or MCP tool call) failed with `400 ... code_execution tool use ... found without a corresponding code_execution_tool_result block`. The patch keeps `caller` and accepts `code_execution_tool_result` and the other server tool result blocks (`web_fetch_`, `bash_code_execution_`, `text_editor_code_execution_`, `tool_search_`) in the stream and the replay. A port of the PR below to the compiled 4.2.7 code, plus one change the PR lacks: `messages/core` (`allowedTypesByProvider.anthropic` in `modifyContent`) also allows the server tool result types, because the graph passes the final Anthropic message through `modifyDeltaProperties`, which turned `code_execution_tool_result` into an empty `text` block, so the results never reached the replay (Anthropic resends a missing result once, and the request after that failed with the same 400; seen on turns of four or more requests) | Reported upstream as LibreChat-AI/agents#690; fix proposed in LibreChat-AI/agents#720 (open, replacements 1-4) and LibreChat-AI/agents#731 (open, own, replacement 5); drop the patch after upgrading to a LibreChat whose `@librechat/agents` includes both |
| `patch-anthropic-container.sh` | `@librechat/agents` `dist/{cjs,esm}/llm/anthropic/index.*` (`_streamResponseChunks`, `_streamChatModelEvents`; a helper function is added before `_toolsInParams`) | With `web_search_20260209` and later a turn can hold `code_execution` (dynamic filtering) and, in parallel, a client MCP tool call. The next request of the same reply sends the client tool result and must repeat the container of the previous response as `container: "<id>"`; the agents library parses `container` into `additional_kwargs` but never sends it, so Anthropic answered `400 container_id is required when there are pending tool uses generated by code execution with tools`. The patch takes the id from the latest AI message of the current turn (after the last human message; messages injected inside a turn, such as hook contexts, do not end it; a container of an earlier turn is never reused, because it may have expired) and passes it as `container` unless one is already set. Needed only with `patch-websearch.sh` | Own change, proposed upstream as LibreChat-AI/agents#732 (open); drop the patch after upgrading to a LibreChat whose `@librechat/agents` passes the container id itself |

Every patch fails the build if its source text is not found exactly once, so an upgrade cannot skip one silently.

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

`browser_snapshot` without a `filename` still returns the whole snapshot inline (about 90 KB for a long Wikipedia article); no flag prevents it, so the bot rules must forbid it. On the Anthropic and Google bots the cap `maxToolResultChars` is 500,000 and lets such a snapshot through whole; only the openAI bots keep 40,000 (section "Bots"). `browser_find` (search in the snapshot, with `maxResults` and an optional `filename`) is available as well.

`./data/web` is mounted at the same path `/data/web` in `playwright` and `tools`: a path returned by the browser works in the terminal. The browser may write only there (its working directory and `--output-dir`; other paths are refused, `file:` URLs are blocked). The directory is scratch space: it also receives console logs of the browser, downloaded PDFs and Jina Reader output. When its files exceed 200 MB (`--output-max-size`), the browser deletes the oldest ones after each tool call; no cron job is needed. Files of the `tools` container are root-owned, which is fine for deletion because the directory belongs to the host user; bots keep files directly in `/data/web`, without subdirectories.

The browser has no authentication. It sits on its own `browser` network, shared only with `librechat` (the bots reach it through LibreChat), and is not on the `default` network: it cannot open `tools:8000` (the shell MCP server without authentication) or `mongodb` (the `db` network). It can reach `librechat:3080` and the whole internet (the `browser` network is a regular bridge, not internal; the browser needs the internet). Known remaining reach: the Docker gateway of the host and the cloud metadata service `169.254.169.254` (Oracle; version 1 of its API answers without a token). Like the shell access of the `tools` container, the browser is open to anyone who can talk to a bot with these servers.

Browser state lives only as long as one MCP session. `--isolated` keeps the profile in memory (cookies, logins, open tabs); each MCP session gets its own isolated context. In `librechat.yaml` the `playwright` server has a `requestHeaders` entry with `{{LIBRECHAT_BODY_CONVERSATIONID}}`; it is not used by the server, its purpose is to make LibreChat open a separate MCP session for each chat request instead of one shared connection for all chats (otherwise all chats would share one browser tab and concurrent chats would overwrite each other's page). Within one turn (one request, including all its tool calls) the page stays open; the session is closed when the turn ends, so the next turn starts with an empty browser and the bot opens the page again. Snapshot files in `/data/web` remain and can be searched in the next turn. Chromium takes about 300 MB when idle and more on heavy pages: the container is limited to 3 GB (`mem_limit`) and has a 1 GB `/dev/shm`.

## Bots

A bot is an item of `modelSpecs` in `librechat.yaml`: a model, a label, a description, the connected `tools` MCP server and a short instruction (`promptPrefix`). The bot's actual prompt is not stored in this repository. The instruction makes the bot read two files from the vault whenever their full text is missing from the conversation: the shared bot rules and the file of its own role (a `text` block in each). That happens at the start, and again after LibreChat has trimmed or summarized old tool results of a long conversation. Those texts become the bot's system prompt. Editing a prompt in Obsidian therefore takes effect without a redeploy: the `tools` container pulls the vault clone every minute, and the next conversation reads the new text.

Every bot except the three English ones and `Scribe` has `subagents` enabled with `allowSelf: false`: the model gets a `subagent` tool with two types, the saved agents Researcher and General (section "The saved agents"). Each type has a variant per provider: the Anthropic bots list `agent_ids: [agent_researcher_anthropic, agent_general_anthropic]`, the Google bots (`Erudite-assistant-Carbon`, `Erudite-assistant-Hydrogen`, `Brilliant-Sage`) list `[agent_researcher_google, agent_general_google]`. A subagent runs without the conversation history, and only its final text returns to the conversation. Search results, pages and file contents it reads therefore do not stay in the conversation and are not resent with every later request. A subagent cannot start subagents itself. When a bot uses which type is set by the shared bot rules in the vault (section ПОДАГЕНТЫ).

Bots:

| Bot | Provider | Model |
| --- | --- | --- |
| `Quick` | Anthropic | `claude-opus-5-5`, effort `medium`, native web search |
| `Erudite-assistant-Fable` | Anthropic | `claude-fable-5-2`, effort `medium`, native web search |
| `Erudite-assistant-Carbon` | Google | `gemini-4-carbon`, thinking level `high`, native web search (Google Search grounding) |
| `Erudite-assistant-Hydrogen` | Google | `gemini-4-hydrogen`, thinking level `high`, native web search (Google Search grounding) |
| `Doctor` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `BackEnder` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Backender-villain` | Google | `gemini-4-hydrogen`, thinking level `high`, native web search (Google Search grounding) |
| `Insightful-genius` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Avtor` | Anthropic | `claude-opus-5-5`, effort `high`, native web search |
| `Brilliant-Sage` | Google | `gemini-4-hydrogen`, thinking level `high`, native web search (Google Search grounding) |
| `English-friend` | OpenAI | `gpt-5.4-mini` |
| `Engspeech-fixer` | OpenAI | `gpt-5.4`, reasoning effort `high`, Responses API |
| `WingswingMan` | OpenAI | `gpt-5.4-mini` |
| `Scribe` | Anthropic | `claude-haiku-5-5`, effort `low`, no web search |

Each bot reads the role file with its own name from the `prompts` folder of the vault (`Doctor.md`, `BackEnder.md`, ...; the Erudite variants share `Erudite-assistant.md`). `Scribe` is the exception to the two files: it reads only its role file `Scribe.md`, which holds the few git steps it needs. It writes every message word for word, with the date and time, at the top of the vault note `Фаст заметки` and pushes the commit; the phone's voice input fills the message.

All Erudite-assistant variants read the same role file. Web search is the provider's native tool (`web_search: true` in the preset), not LibreChat's own web search, which would replace it and is not configured. `interface.webSearch` is nevertheless `true`: it grants the roles the web search permission, and without it LibreChat silently strips the native tool too. The web search button in the chat starts LibreChat's own search; leave it off. LibreChat 0.8.9 has price and context window data for `gemini-4-hydrogen` (window 1,048,576 tokens, output limit 65,536, $1.5 input / $7.5 output / $0.075 cached input per million tokens) but none for `gemini-4-carbon`: the Carbon preset sets `maxContextTokens` explicitly (otherwise the window becomes 1,024 tokens), and spending on Carbon is counted at the generic "gemini" rate, cached input tokens included at the full input price. The Hydrogen presets set `maxContextTokens` too, the same history cap as on every bot. The sources of the native search are not shown in the UI.

All bots except `Scribe` also get the `playwright` MCP server (`mcpServers` of each spec). The rules for reading the web (search first, then Jina Reader, the browser when Jina fails or the page needs interaction, PDFs through `curl` and `pdftotext`) live in the shared bot rules in the vault, not here.

`maxToolResultChars` in `librechat.yaml` caps a single tool result in characters. A longer result is cut: its head and tail are kept and the middle is replaced by a `[truncated: N chars exceeded <limit> limit]` notice. `endpoints.all` sets 40,000 for every endpoint: without a cap one read of a web page returned about 206k tokens, which was resent with every later request of the conversation. The blocks `endpoints.anthropic` and `endpoints.google` hold only this key and raise the cap to 500,000 for the bots on these providers and for their subagents (the block of an endpoint wins over `all`, and a block with this key alone changes nothing else); the OpenAI bots keep 40,000. This is a workaround, and the reason is screenshots: LibreChat counts the base64 of an image against the text cap (LibreChat-AI/agents PR #677, still open, gives images their own budget). After upgrading to a LibreChat whose `@librechat/agents` includes that change, drop both blocks and keep the single 40,000 cap for all providers; that also makes any new provider work with screenshots. Until then, a new provider whose bots take screenshots needs its own block. The picture from `browser_take_screenshot` (without `filename`) counts against the cap as base64 characters, a 1280x800 screenshot takes up to about 400,000 of them (a chart on Artificial Analysis about 190,000), and a picture over the cap is dropped from the result with the notice `[omitted 1 oversized atomic tool-content block: image_url]`. The model is billed for the picture by its pixels (about 1,400 tokens for 1280x800), and LibreChat counts the picture in its own token budget by its dimensions too, not by the characters; on the Google and OpenAI providers the picture is attached only to the request that follows the tool call and is not resent later, while on Anthropic the images of the last 10 tool results go with every later call of the same reply (read from the prompt cache, patch `patch-tool-images-run.sh`); earlier turns never carry them. A cap of 500,000 also lets a large text result through, so the bot rules prevent those at the source: pages are read into files and searched there, and `read_file` is never given a URL.

`enforce` is `false` and `interface.modelSelect` is `true`: models outside the specs stay selectable. LibreChat 0.8.9 talks to `gpt-6-luna` through the Responses API, so its tool calls work with any reasoning effort. `gpt-5.4` and `gpt-5.4-mini` run on Chat Completions by default, and there they do not reason (the default effort is `none`). With any other reasoning effort, gpt-5.4 rejects function tools in Chat Completions with a 400 ("use /v1/responses or set reasoning_effort to 'none'"), so `Engspeech-fixer` sets `reasoning_effort: high` together with `useResponsesApi: true`; a bot that needs reasoning on these models does the same.

Every bot sets `maxContextTokens: 550000`: LibreChat prunes older messages beyond it, which keeps a long conversation from being re-sent whole (after a pause longer than the prompt cache lifetime, the whole history is written to the cache again at the full price). The `gpt-5.4-mini` bots are the exception: the model's window is 400k, so LibreChat's own limit for it is kept. `Scribe` sets 100,000: Haiku 5.5 doubles its price for prompts over 100k tokens, and old dictations are of no use to the next one. The cap does not limit the server-side loop of Anthropic's web search inside one request.

The tool descriptions of `tools` (~12,100 tokens) and `playwright` (~6,000 tokens) go with every request. Every bot sets `deferLoading` (a YAML anchor, `&unusedTools`, defined on the first bot) to the 16 tools the bots never called: their descriptions (~4,700 tokens) are left out, and the model reaches one through LibreChat's `tool_search` if it needs it. A found tool joins the tool list for the rest of the conversation; the tool list opens the cached prefix, so that change rewrites the prompt cache once and costs an extra model round. Defer only tools that are rarely used; before adding one, count its calls in `messages` (`content[].tool_call.name`). `Scribe` has its own list instead: every tool of `tools` except the four it uses (`read_file`, `write_file`, `edit_block`, `start_process`). The `deferred_tools` agent capability that this needs is on by default.

A new bot is a new `modelSpecs` item in `librechat.yaml` (with its role file in the vault), then:

```bash
docker compose up -d --force-recreate librechat
```

## The saved agents

Two types of saved LibreChat agents are the only subagent types of the bots: Researcher and General. Each type exists in two variants, one per provider of the calling bot: `agent_researcher_anthropic` and `agent_general_anthropic` for the Anthropic bots, `agent_researcher_google` and `agent_general_google` for the Google bots. Their definitions live in this repository and a script writes them into the LibreChat database, so they are reviewed and versioned like the rest of the config. The two variants of a type share the description, the tools, `recursion_limit` 150 and the prompt; they differ in the provider and the model parameters, because the preset of the calling bot is not passed to a subagent. `recursion_limit` is the step limit of a subagent: 3 graph steps are one model turn, so 150 gives a subagent 50 turns (the bots themselves keep the 75 of `endpoints.agents.recursionLimit` in `librechat.yaml`, about 25 rounds of tool calls before the step-budget hook). Tests showed 25 turns are too few: a subagent that runs out of turns loses its whole result silently. The prompts keep a soft budget of 33 tool calls (LibreChat warns only the main agent before its limit, so the prompt is the only signal a subagent gets to stop and return what it found); a full 50-turn run on Sonnet costs about $1.

- The Anthropic variants run on Sonnet (`claude-sonnet-5-5`), effort `medium`, with the provider's native web search and a prompt cache of 5 minutes, like the Anthropic bots.
- The Google variants run on `gemini-4-hydrogen`, thinking level `medium`, with Google Search grounding (`web_search: true`). `maxContextTokens` (550,000) and `maxOutputTokens` (32,768) are set explicitly: they cap the history sent and the length of a reply below the model's own limits (window 1,048,576 tokens, output 65,536, both known to LibreChat 0.8.9).

| Agent | For | Tools |
| --- | --- | --- |
| Researcher | search and reading on the web and in the vault files; returns a short summary with figures and sources | 11: `start_process`, `read_process_output`, `read_file` from `tools`; `browser_navigate`, `browser_snapshot`, `browser_take_screenshot`, `browser_click`, `browser_find`, `browser_type`, `browser_press_key`, `browser_wait_for` from `playwright` |
| General | any other delegated work: edits across many vault notes, commands and diagnostics on the VPS host, data processing in the terminal | 34: all 15 tools of `tools` and 19 of the 25 tools of `playwright` |

The files in `agents/`:

- `<name>.json` is the settings: the fields shared by all variants (`name`, `description`, `tools`, `mcpServerNames`, `recursion_limit`, `category`) and a `variants` array. A variant sets its own `id`, `provider`, `model` and `model_parameters`. A tool is written `<tool>_mcp_<server>`. The description is what the calling bot's model sees when it picks the subagent type.
- `<name>.md` is the system prompt of every variant of the type: the text of the first fenced block tagged `text`. It is stored here and not in the vault, unlike the bot prompts, because only LibreChat reads it; no bot opens these files. General reads the shared bot rules from the vault itself when it edits notes, runs commands on the VPS or searches the web.
- `apply.js` creates or updates one agent per variant of every type that has both a `.json` and a `.md` with the same base name.

The Researcher is a small, cheap start: a short prompt and few tools. "Search and reading only" is a rule of its prompt, not a technical limit: `start_process` opens a terminal that could also write. General gets every tool of `tools`; of `playwright` it does not get `browser_evaluate`, `browser_run_code_unsafe`, `browser_drag`, `browser_drop`, `browser_resize` and `browser_emulate_media`. The two script tools are left out because the bot rules forbid page-scraping scripts (the page is read through snapshot files and the terminal), and the other four are not used for reading or editing; every tool description is sent with each request, so unused tools only cost tokens. A tool added to a server later is not picked up by itself: add it to the `.json`.

Subagents never commit or push. General edits files without committing and lists the changed files; the calling bot reviews `git diff` and commits.

Run the script on the VPS after a deploy that changed `agents/`, and once on a new installation after the first login (it needs the ADMIN user), and again after every new user is created:

```bash
docker compose exec -T librechat node /app/parley-agents/apply.js
```

`./agents` is mounted read-only into the `librechat` container at `/app/parley-agents` (a directory mount, so `git pull` shows up at once). The script uses LibreChat's own modules, as its agents API does: version history is kept (an update adds a version, an identical run adds nothing) and the single ADMIN user gets the owner role on each agent, and every other user gets view access (needed so that their bots can start the agents as subagents). It fails unless the database holds exactly one ADMIN user. After creating a new user, run `apply.js` again: otherwise that user's bots cannot start subagents. Every definition is checked before the first write, and one invalid definition stops the whole run with nothing changed: the model is in `ANTHROPIC_MODELS` (an Anthropic variant) or `GOOGLE_MODELS` (a Google one), the variant ids are unique, the category exists, every tool is one that the `tools` and `playwright` servers actually offer (the script lists them over MCP, the same names LibreChat registers), and the prompt block exists. `--dry-run` does all the checks and writes nothing. Output has one line per agent and holds only ids and counts.

A change takes effect immediately, without a restart: the next subagent run reads the agent from the database. A change of the `subagents` block in `librechat.yaml` still needs `docker compose up -d --force-recreate librechat`. The files are the source of truth: edits of an agent in the LibreChat UI are overwritten by the next run. The `id` of an agent is fixed at creation, so renaming a variant id in `agents/*.json` makes the next run create a new agent and leaves the old one in the database; delete the old one through the LibreChat UI, logged in as its owner (the ADMIN user): agent builder, pick the agent, Delete. `apply.js` never deletes agents.

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
- `PARLEY_TEST_EMAIL`, `PARLEY_TEST_PASSWORD` — the test user of the scripted checks, optional (section "Testing the bots").
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
4. Create the saved agents: `docker compose exec -T librechat node /app/parley-agents/apply.js` (section "The saved agents").
5. Only after that does the administrator add the Caddy route (section 7).

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

If the pull changed `agents/`, apply the saved agents afterwards (the container must already run the new compose file, which mounts the directory):

```bash
docker compose exec -T librechat node /app/parley-agents/apply.js
```

`librechat.yaml` is bind-mounted as a single file: compose does not notice its changes, and `git pull` replaces the file (new inode), so the running container keeps the old version. After a change to `librechat.yaml` recreate LibreChat explicitly:

```bash
docker compose up -d --force-recreate librechat
```

Versions are pinned: LibreChat in `librechat/Dockerfile` (the `FROM` tag), MongoDB and the Playwright MCP image in `docker-compose.yml`, the npm packages in `tools/Dockerfile`; changing them is a separate, deliberate change. A LibreChat upgrade is a change of the `FROM` tag; the build fails if the text patched by one of the `librechat/patch-*.sh` scripts (table in "Architecture") changed, and then the script is adjusted to the new files or dropped if the upstream fixed the problem.

Logs of all containers are rotated by Docker (3 files of 10 MB each per container). The `tools` container does not log tool calls: supergateway runs with `--logLevel none`, otherwise it would write every JSON-RPC message, including the contents of the notes, into the log.

## Adding a model

Append the model name to `ANTHROPIC_MODELS`, `GOOGLE_MODELS` or `OPENAI_MODELS` in `.env` on the VPS, then recreate the container: `docker compose up -d --force-recreate librechat`. A bot's model must stay in the matching `*_MODELS` list: otherwise LibreChat silently substitutes the first model of the list (the models of the saved agents as well: `apply.js` checks them against `ANTHROPIC_MODELS` and `GOOGLE_MODELS`). The models of the bots above need these entries: `gpt-5.4` and `gpt-5.4-mini` in `OPENAI_MODELS`, `gemini-4-carbon` and `gemini-4-hydrogen` in `GOOGLE_MODELS` (the `.env.example` template has them; an existing `.env` on the VPS is updated by hand). A model unknown to the installed LibreChat version needs `maxContextTokens` in the bot preset, as in `Erudite-assistant-Carbon`; otherwise the context window falls back to 1,024 tokens.

## Testing the bots

`test/` holds a harness that sends real chat turns to the bots and reports what happened, the way the web client would. It is for a live smoke check after changes to `librechat.yaml`, `agents/` or the patches.

- `chat.mjs` runs inside the `librechat` container: it logs in as the test user, sends one turn to a bot (the spec preset fields go with it, as the web client sends them) and waits for the reply. A name starting with `agent_` chats with that saved agent directly. It can attach an image (`--image`) or a document (`--file`, with `--file-mode provider|text`) and continue a conversation (`--conv`, `--parent`).
- `report.js` is a mongosh report of a conversation: tool calls, subagent calls with their tools and final text, the final reply and the cost by context and model.
- `steps.js` is a mongosh dump of the last reply part by part: tool calls, think and text parts in order, with the parts of subagents indented under their call.
- `run.sh` is the driver from a workstation: it copies the scripts to the VPS over ssh, runs the chat in the container and prints the report.

The test user is created once, on the VPS:

```bash
docker compose exec librechat npm run create-user
docker compose exec -T librechat node /app/parley-agents/apply.js
```

Use an address and a password of your choice, no two-factor authentication, role USER. The second command gives the new user view access to the saved agents. Put the credentials into `.env` on the VPS as `PARLEY_TEST_EMAIL` and `PARLEY_TEST_PASSWORD`; the driver reads them there and never prints them.

Environment of `run.sh` on the workstation:

| Variable | Meaning |
| --- | --- |
| `PARLEY_SSH` | ssh destination of the VPS: an alias from `~/.ssh/config` or `user@host`; required |
| `PARLEY_SSH_KEY` | ssh key, passed as `-i`; optional |
| `PARLEY_DIR` | the compose project directory on the VPS; default `/opt/parley` |
| `PARLEY_TAG` | isolates the staging files, so two runs can go in parallel; optional |

```bash
export PARLEY_SSH=vps
./test/run.sh Quick "question"                                  # one turn to a bot (a modelSpecs name), then the report
./test/run.sh Quick "follow-up" --conv <conversationId> --parent <responseMessageId>
./test/run.sh Quick "what is in the picture?" --image ./picture.png
./test/run.sh Quick "summarize" --file ./document.pdf           # --file-mode text: "Upload as Text"
./test/run.sh agent_researcher_anthropic "question"             # a saved agent directly, no bot
./test/run.sh --report <conversationId>                         # the report of an existing conversation
./test/run.sh --steps <conversationId>                          # the last reply part by part
```

The first turn prints `conversationId` and `responseMessageId`; the follow-up takes them from there. `--dump` keeps the raw SSE stream in `test/last-sse.txt` (ignored by git); `--upload-only` only uploads the attachment and prints the response.

Notes:

- Every run spends real API money; a long Researcher run costs about $1.
- LibreChat limits logins (about 7 per 5 minutes). `chat.mjs` caches the token in the container (`/tmp/parley-token`) and logs in again only on a 401.
- The browser (Playwright MCP) is one shared session for all conversations, so run browser scenarios one at a time.
- The test conversations stay under the test user; they are not visible to the owner's account.
