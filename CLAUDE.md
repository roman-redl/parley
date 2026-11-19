# CLAUDE.md — parley

Config repository of a personal "Poe" on a VPS: docker-compose, `librechat.yaml` (including the bots in `modelSpecs`), the `.env.example` template, the tools container (`tools/`) and the definitions of the saved agents Researcher and General (`agents/`). There is no service code. Architecture and deployment are described in [README.md](README.md).

## Keys and running

- API keys (Anthropic, Gemini, OpenAI) exist only in `.env` on the VPS. The repository holds only `.env.example` with empty secrets; the real `.env` and the `data/` directory are ignored by git.
- Do not run anything with keys locally. Calls to paid APIs are made only from the VPS. Do not start containers on this machine; `docker compose config` with a dummy `.env` and YAML checks are fine.
- Do not print secrets from the VPS to the terminal or chat.

## Language

Documentation and comments are in English (the repository is public). Instructions for models in `librechat.yaml` (`promptPrefix` in `modelSpecs`) are in Russian: they are for the Russian vault.

## Change rules

- Versions are pinned: LibreChat in the `FROM` tag of `librechat/Dockerfile` (the compose file builds `parley-librechat:local` from it), `mongodb` and the `playwright` image (`mcr.microsoft.com/playwright/mcp`) in `docker-compose.yml`, npm packages in `tools/Dockerfile`. Upgrades are deliberate: read the project changelog first, then change the version. A LibreChat upgrade is a change of the `FROM` tag; the build checks the patterns that `librechat/patch-pwa.sh` (PWA theme colour and the manifest revision in `sw.js`), `librechat/patch-agents.sh` (Anthropic server tool calls excluded from eager local execution in `@librechat/agents`), `librechat/patch-shift.sh` (inline script in `index.html` that disables the Shift-held Archive/Delete buttons) and `librechat/patch-images.sh` (resize limits of uploaded images in `api/server/services/Files/images/resize.js`) patch and fails if they changed, then the script is adjusted (or dropped if the upstream fixed the problem). Keep `mongodb` at the version used by the official LibreChat `docker-compose.yml` of the chosen tag.
- Take the `version` field of `librechat.yaml` from `librechat.example.yaml` at the tag of the LibreChat version in use. Validate `modelSpecs` fields against the schema at the same tag (`packages/data-provider/src/models.ts`, `schemas.ts`).
- A model is added as an entry in `ANTHROPIC_MODELS`, `GOOGLE_MODELS` or `OPENAI_MODELS` in `.env` on the VPS, then the container is recreated: `docker compose up -d --force-recreate librechat`.
- The `playwright` service relies on `--snapshot-mode none` (action results carry no page snapshot) and on the `filename` parameter of `browser_snapshot` (the snapshot goes to a file in `/data/web`, shared with the `tools` container). Before upgrading the image, check that both still exist, and run the flags from `docker-compose.yml` in a throwaway container on the VPS: navigate results must stay a few lines long.
- Bots are `modelSpecs` items in `librechat.yaml`. A bot's prompt and the shared bot rules live in the Obsidian vault (the `prompts` folder of the notes repository, mounted at `/data/notes` in the tools container) and are never copied into this repository: the short instruction in `promptPrefix` makes the bot read them whenever their text is missing from the conversation. A new bot is a new `modelSpecs` item, then `docker compose up -d --force-recreate librechat`.
- The saved agents Researcher (`agent_researcher`, search and reading, 11 tools) and General (`agent_general`, any other work, all 15 tools of `tools` and 19 of `playwright`) are the only subagent types of the bots (`subagents` in every non-English spec: `allowSelf: false`, `agent_ids: [agent_researcher, agent_general]`). Settings are in `agents/<name>.json`, the prompt in `agents/<name>.md` (the first `text` block): an exception to "prompts live in the vault", because only LibreChat uses them and no bot reads these files; General reads the shared bot rules from the vault itself. Tools are written `<tool>_mcp_<server>` and must exist on the `tools` and `playwright` servers (`browser_evaluate`, `browser_run_code_unsafe`, `browser_drag`, `browser_drop`, `browser_resize` and `browser_emulate_media` are left out of General on purpose, README); the model must be in `ANTHROPIC_MODELS`. Subagents never commit: the calling bot reviews `git diff` and commits. `agents/apply.js` writes every agent that has a `.json` and a `.md` into LibreChat and runs only inside the `librechat` container on the VPS (README, "The saved agents"); locally only `node --check agents/apply.js`. Test changes to it with `--dry-run`, which writes nothing.
- The bots see only the DesktopCommander tools listed with `--tools` in `tools/entrypoint.sh`; a tool missing from the list is dropped silently. Before upgrading DesktopCommander, compare its tool names (`tools/list`) with that list.
- The DesktopCommander config is set by `tools/init-config.mjs` on every container start; do not edit the file by hand. File operations are limited to `/data`, the terminal is not: it also has ssh access to the VPS host (`ssh vps`, user `ubuntu` with passwordless sudo), a deliberate choice of the owner (README, section 2).

## Deployment

On the VPS: `git pull`, `mkdir -p data/web` (as the deploying user; if Docker already created it as root, `sudo chown "$(id -u):$(id -g)" data/web`), then `docker compose up -d --build --remove-orphans`; if `agents/` changed, `docker compose exec -T librechat node /app/parley-agents/apply.js` after it (takes effect at once, no restart). Files on the VPS are not edited by hand, except `.env`. The Caddy route is configured by the administrator in selfhost-music: Caddy proxies to `parley-librechat:3080` over the shared `CADDY_NETWORK` network.

Further rules come from the root CLAUDE.md of the personal projects.
