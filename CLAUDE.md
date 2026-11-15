# CLAUDE.md — parley

Config repository of a personal "Poe" on a VPS: docker-compose, `librechat.yaml` (including the bots in `modelSpecs`), the `.env.example` template and the tools container (`tools/`). There is no service code. Architecture and deployment are described in [README.md](README.md).

## Keys and running

- API keys (Anthropic, Gemini, OpenAI) exist only in `.env` on the VPS. The repository holds only `.env.example` with empty secrets; the real `.env` and the `data/` directory are ignored by git.
- Do not run anything with keys locally. Calls to paid APIs are made only from the VPS. Do not start containers on this machine; `docker compose config` with a dummy `.env` and YAML checks are fine.
- Do not print secrets from the VPS to the terminal or chat.

## Language

Documentation and comments are in English (the repository is public). Instructions for models in `librechat.yaml` (`promptPrefix` in `modelSpecs`) are in Russian: they are for the Russian vault.

## Change rules

- Image versions (`librechat`, `mongodb`, `open-webui`) and npm packages in `tools/Dockerfile` are pinned. Upgrades are deliberate: read the project changelog first, then change the version. Keep `mongodb` at the version used by the official LibreChat `docker-compose.yml` of the chosen tag.
- Take the `version` field of `librechat.yaml` from `librechat.example.yaml` at the tag of the LibreChat version in use. Validate `modelSpecs` fields against the schema at the same tag (`packages/data-provider/src/models.ts`, `schemas.ts`).
- A model is added as an entry in `ANTHROPIC_MODELS`, `GOOGLE_MODELS` or `OPENAI_MODELS` in `.env` on the VPS, then the container is recreated: `docker compose up -d --force-recreate librechat`.
- Bots are `modelSpecs` items in `librechat.yaml`. A bot's prompt and the shared bot rules live in the Obsidian vault (the `prompts` folder of the notes repository, mounted at `/data/notes` in the tools container) and are never copied into this repository: the short instruction in `promptPrefix` makes the bot read them at the start of each conversation. A new bot is a new `modelSpecs` item, then `docker compose up -d --force-recreate librechat`.
- The DesktopCommander config is set by `tools/init-config.mjs` on every container start; do not edit the file by hand. File operations are limited to `/data`, the terminal is not.

## Deployment

On the VPS: `git pull`, then `docker compose up -d --build`. Files on the VPS are not edited by hand, except `.env`. The Caddy route is configured by the administrator in selfhost-music: Caddy proxies to `parley-librechat:3080` and `parley-webui:8080` over the shared `CADDY_NETWORK` network.

Further rules come from the root CLAUDE.md of the personal projects.
