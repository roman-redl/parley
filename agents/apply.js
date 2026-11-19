#!/usr/bin/env node
'use strict';

/*
 * Creates or updates the saved LibreChat agents from agents/<name>.json (settings) and
 * agents/<name>.md (the prompt: the first fenced block tagged `text`). Every .json that has a
 * .md with the same base name is an agent family: the file holds the fields shared by all its
 * agents (name, description, tools, ...) and a `variants` array; every variant is one LibreChat
 * agent with its own `id`, `provider`, `model` and `model_parameters`, and all variants share
 * the one prompt. Idempotent: run it after every deploy that changes the files in agents/.
 * Runs inside the librechat container, where the directory is mounted read-only as
 * /app/parley-agents:
 *
 *   docker compose exec -T librechat node /app/parley-agents/apply.js [--dry-run]
 *
 * All definitions are loaded and validated, and the existing agents are compared, before the
 * first write: one invalid definition stops the whole run with nothing changed.
 * --dry-run does all of that and then writes nothing.
 *
 * The script goes through LibreChat's own modules (the same calls as the agents API handlers
 * in api/server/controllers/agents/v1.js) instead of writing to MongoDB directly, so version
 * history, the MCP server index and the access entries stay the way the UI would leave them.
 * Output never contains secrets: only ids, counts and names.
 */

const fs = require('fs');
const path = require('path');
const { isDeepStrictEqual } = require('util');
const { load: loadYaml } = require('js-yaml');

const DRY_RUN = process.argv.includes('--dry-run');
// The tool names the model sees are built from the MCP server's own tool list and the server
// name in this file, so the server URLs are read from the same config LibreChat uses.
const LIBRECHAT_YAML = '/app/librechat.yaml';
const MCP_TIMEOUT_MS = 20000;
// Written on update. `id` and `author` are fixed at creation and never touched afterwards.
const FIELDS = [
  'name',
  'description',
  'instructions',
  'provider',
  'model',
  'model_parameters',
  'tools',
  'mcpServerNames',
  'recursion_limit',
  'category',
];

// Set per variant in `variants`; everything else in the .json is shared by all variants.
const VARIANT_FIELDS = ['id', 'provider', 'model', 'model_parameters'];
// The *_MODELS environment variable that lists the models LibreChat accepts per provider.
const MODELS_ENV = { anthropic: 'ANTHROPIC_MODELS', google: 'GOOGLE_MODELS' };

const fail = (message) => {
  throw new Error(message);
};

/** The prompt is the text of the first fenced block tagged `text`; the rest of the file is notes. */
function readInstructions(name) {
  const markdown = fs.readFileSync(path.join(__dirname, `${name}.md`), 'utf8');
  const match = markdown.match(/^```text[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*$/m);
  if (!match) {
    fail(`${name}.md has no fenced block tagged \`text\`: write the prompt there first`);
  }
  const text = match[1].trim();
  if (!text) {
    fail(`the \`text\` block in ${name}.md is empty`);
  }
  return text;
}

/** Returns one { id, definition } per variant: the shared fields, the variant's own, the prompt. */
function readDefinitions(name) {
  const { variants, ...shared } = JSON.parse(
    fs.readFileSync(path.join(__dirname, `${name}.json`), 'utf8'),
  );
  for (const key of ['name', 'category']) {
    if (typeof shared[key] !== 'string' || !shared[key]) {
      fail(`${name}.json: "${key}" must be a non-empty string`);
    }
  }
  for (const key of VARIANT_FIELDS) {
    if (key in shared) {
      fail(`${name}.json: "${key}" belongs inside "variants", not at the top level`);
    }
  }
  for (const key of ['tools', 'mcpServerNames']) {
    if (!Array.isArray(shared[key]) || shared[key].length === 0) {
      fail(`${name}.json: "${key}" must be a non-empty array`);
    }
  }
  if (new Set(shared.tools).size !== shared.tools.length) {
    fail(`${name}.json: "tools" has duplicates`);
  }
  if (!Array.isArray(variants) || variants.length === 0) {
    fail(`${name}.json: "variants" must be a non-empty array`);
  }

  const instructions = readInstructions(name);
  return variants.map((variant, index) => {
    const label = `${name}.json: variants[${index}]`;
    if (variant === null || typeof variant !== 'object' || Array.isArray(variant)) {
      fail(`${label} must be an object`);
    }
    const unknown = Object.keys(variant).filter((key) => !VARIANT_FIELDS.includes(key));
    if (unknown.length > 0) {
      fail(`${label}: unknown fields ${unknown.join(', ')} (allowed: ${VARIANT_FIELDS.join(', ')})`);
    }
    const { id, ...own } = variant;
    for (const key of ['id', 'provider', 'model']) {
      if (typeof variant[key] !== 'string' || !variant[key]) {
        fail(`${label}: "${key}" must be a non-empty string`);
      }
    }
    return { id, definition: { ...shared, ...own, instructions } };
  });
}

/** Base names of the agents: a .json with a .md of the same name next to it. */
function findAgentNames() {
  const files = new Set(fs.readdirSync(__dirname));
  const names = [];
  for (const file of [...files].sort()) {
    if (!file.endsWith('.json')) {
      continue;
    }
    const name = file.slice(0, -'.json'.length);
    if (files.has(`${name}.md`)) {
      names.push(name);
    } else {
      console.log(`note: ${file} has no ${name}.md, skipped`);
    }
  }
  if (names.length === 0) {
    fail('no agents found: expected agents/<name>.json with agents/<name>.md');
  }
  return names;
}

/** Splits `<tool>_mcp_<server>`; the longest matching server name wins. */
function splitToolKey(key, servers, delimiter) {
  const matches = servers
    .filter((server) => key.endsWith(delimiter + server))
    .sort((a, b) => b.length - a.length);
  if (matches.length === 0) {
    return null;
  }
  return { server: matches[0], tool: key.slice(0, key.length - delimiter.length - matches[0].length) };
}

const serverToolsCache = new Map();

/** Lists the tool names a configured MCP server really offers (read-only `tools/list`). */
function listServerTools(serverName) {
  if (!serverToolsCache.has(serverName)) {
    serverToolsCache.set(serverName, fetchServerTools(serverName));
  }
  return serverToolsCache.get(serverName);
}

async function fetchServerTools(serverName) {
  const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
  const {
    StreamableHTTPClientTransport,
  } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');

  const config = loadYaml(fs.readFileSync(LIBRECHAT_YAML, 'utf8'));
  const url = config?.mcpServers?.[serverName]?.url;
  if (!url) {
    fail(`mcpServers.${serverName}.url is missing in ${LIBRECHAT_YAML}`);
  }
  const client = new Client({ name: 'parley-agents-apply', version: '1.0.0' });
  try {
    await client.connect(new StreamableHTTPClientTransport(new URL(url)), {
      timeout: MCP_TIMEOUT_MS,
    });
    const names = [];
    let cursor;
    do {
      const page = await client.listTools({ cursor }, { timeout: MCP_TIMEOUT_MS });
      names.push(...page.tools.map((tool) => tool.name));
      cursor = page.nextCursor;
    } while (cursor);
    return names;
  } catch (error) {
    fail(`cannot list tools of MCP server "${serverName}": ${error.message}`);
  } finally {
    await client.close().catch(() => {});
  }
}

/** Returns a list of problems; empty when the definition is consistent with this instance. */
async function validate({ definition, delimiter, AgentCategory }) {
  const problems = [];
  const { provider, model, model_parameters: params, tools, mcpServerNames, category } = definition;

  // LibreChat silently replaces a model missing from the *_MODELS list with the first one.
  const modelsVar = MODELS_ENV[provider];
  if (modelsVar === undefined) {
    console.log(`note: no model list known for provider "${provider}", model not checked`);
  } else if (
    !(process.env[modelsVar] ?? '').split(',').map((m) => m.trim()).includes(model)
  ) {
    problems.push(`model "${model}" is not in ${modelsVar}`);
  }
  // Without these LibreChat falls back to a 1,024-token context for gemini-4-* (no data for them).
  if (provider === 'google') {
    for (const key of ['maxContextTokens', 'maxOutputTokens']) {
      if (!Number.isInteger(params?.[key]) || params[key] <= 0) {
        problems.push(`model_parameters.${key} must be a positive integer for a google variant`);
      }
    }
  }
  if (params?.model !== undefined && params.model !== model) {
    problems.push(`model_parameters.model "${params.model}" differs from model "${model}"`);
  }

  if (!(await AgentCategory.exists({ value: category, isActive: true }))) {
    problems.push(`agent category "${category}" does not exist or is inactive`);
  }

  // Group the tools by server, then compare each group with what the server reports.
  const perServer = {};
  for (const key of tools) {
    const split = splitToolKey(key, mcpServerNames, delimiter);
    if (!split) {
      problems.push(`tool "${key}" is not "<tool>${delimiter}<server>" of a server in mcpServerNames`);
      continue;
    }
    (perServer[split.server] ??= []).push(split.tool);
  }
  const usedServers = Object.keys(perServer).sort();
  if (!isDeepStrictEqual(usedServers, [...mcpServerNames].sort())) {
    problems.push('mcpServerNames does not match the servers used by tools');
  }
  for (const server of usedServers) {
    const available = new Set(await listServerTools(server));
    for (const tool of perServer[server]) {
      if (!available.has(tool)) {
        problems.push(`server "${server}" has no tool "${tool}"`);
      }
    }
  }
  return problems;
}

async function main() {
  // connect.js registers the `~` alias for /app/api and opens the MongoDB connection.
  await require('/app/config/connect')();
  const mongoose = require('mongoose');
  const { Constants, AccessRoleIds, ResourceType, PrincipalType } = require('librechat-data-provider');
  // Models first: the services below expect them to be registered.
  const { User, AclEntry, AgentCategory } = require('~/db/models');
  const db = require('~/models');
  const { grantPermission } = require('~/server/services/PermissionService');

  const userCount = await User.countDocuments({});
  if (userCount !== 1) {
    fail(`expected exactly one user, found ${userCount}`);
  }
  const user = await User.findOne({}).select('_id').lean();

  if (!(await db.findRoleByIdentifier(AccessRoleIds.AGENT_OWNER))) {
    fail(`access role ${AccessRoleIds.AGENT_OWNER} not found: LibreChat has not seeded its roles`);
  }

  // Phase 1, no writes: load and validate every definition, and compare it with the stored agent.
  const problems = [];
  const plans = [];
  const seenIds = new Set();
  for (const name of findAgentNames()) {
    try {
      for (const { id, definition } of readDefinitions(name)) {
        // A broken variant is reported under its own id and does not hide the other problems.
        try {
          if (seenIds.has(id)) {
            fail(`id "${id}" is used by more than one agent`);
          }
          seenIds.add(id);
          const found = await validate({
            definition,
            delimiter: Constants.mcp_delimiter,
            AgentCategory,
          });
          problems.push(...found.map((problem) => `${id}: ${problem}`));
          plans.push({ id, definition, existing: await db.getAgent({ id }) });
        } catch (error) {
          problems.push(`${id}: ${error.message}`);
        }
      }
    } catch (error) {
      problems.push(`${name}: ${error.message}`);
    }
  }
  if (problems.length > 0) {
    fail(`invalid definitions, nothing was written:\n  - ${problems.join('\n  - ')}`);
  }

  // Phase 2: create or update each agent, then make sure the user owns it.
  const tag = DRY_RUN ? '[dry-run] ' : '';
  const will = DRY_RUN ? 'would be ' : '';
  for (const { id, definition, existing } of plans) {
    let agent = existing;
    let action;
    if (!existing) {
      action = `${will}created`;
      if (!DRY_RUN) {
        agent = await db.createAgent({ ...definition, id, author: user._id });
      }
    } else {
      // mcpServerNames is an index without a stable order; the other fields compare as stored.
      const sorted = (value) => (Array.isArray(value) ? [...value].sort() : value);
      const changed = FIELDS.filter((field) =>
        field === 'mcpServerNames'
          ? !isDeepStrictEqual(sorted(existing[field]), sorted(definition[field]))
          : !isDeepStrictEqual(existing[field], definition[field]),
      );
      if (changed.length === 0) {
        action = 'unchanged';
      } else {
        action = `${will}updated (${changed.join(', ')})`;
        if (!DRY_RUN) {
          const update = Object.fromEntries(changed.map((field) => [field, definition[field]]));
          // updateAgent snapshots the previous state into `versions` itself.
          agent = await db.updateAgent({ id }, update, { updatingUserId: String(user._id) });
        }
      }
      if (String(existing.author) !== String(user._id)) {
        console.log(`warning: ${id}: the author is ${existing.author}, not the only user`);
      }
    }

    // Owner access for the only user; the upsert makes a repeated run harmless. A missing entry
    // after a failed earlier run is repaired here too.
    const aclQuery = agent && {
      principalType: PrincipalType.USER,
      principalId: user._id,
      resourceType: ResourceType.AGENT,
      resourceId: agent._id,
    };
    const hasAccess = aclQuery ? Boolean(await AclEntry.exists(aclQuery)) : false;
    if (!DRY_RUN) {
      await grantPermission({
        principalType: PrincipalType.USER,
        principalId: user._id,
        resourceType: ResourceType.AGENT,
        resourceId: agent._id,
        accessRoleId: AccessRoleIds.AGENT_OWNER,
        grantedBy: user._id,
      });
    }

    const perServer = definition.mcpServerNames.map(
      (server) =>
        `${server} ${definition.tools.filter((t) => t.endsWith(Constants.mcp_delimiter + server)).length}`,
    );
    console.log(
      `${tag}${id}: ${action}; owner ${hasAccess ? 'already present' : `${will}granted`}; ` +
        `model ${definition.model}, tools ${definition.tools.length} (${perServer.join(', ')}), ` +
        `instructions ${definition.instructions.length} chars`,
    );
  }

  await mongoose.disconnect();
}

main().then(
  () => process.exit(0),
  (error) => {
    // Message only: a stack or an error object could carry connection details.
    console.error(`apply.js failed: ${error.message}`);
    process.exit(1);
  },
);
