// Brings the DesktopCommander config to the required state on every container start.
// The config lives in ~/.claude-server-commander/config.json (a volume in compose).
// Argument: path to the dist directory of the installed package.
//
// If config.json already exists, DesktopCommander does not merge defaults into it,
// so the file is not written by hand: the first start creates it with the standard
// blockedCommands list, and afterwards only the needed fields are changed.
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const dist = process.argv[2];
if (!dist) {
  console.error('usage: init-config.mjs <path to the DesktopCommander dist directory>');
  process.exit(2);
}

const { configManager } = await import(
  pathToFileURL(path.join(dist, 'config-manager.js')).href
);

await configManager.init();

// File operations are limited to /data (the notes and handoff clones).
// The terminal is not limited by this list, by design (DesktopCommander README).
await configManager.updateValue('allowedDirectories', () => ['/data']);
// Telemetry is off; updateValue (unlike setValue) does not touch the network.
await configManager.updateValue('telemetryEnabled', () => false);
await configManager.updateValue('defaultShell', () => '/bin/bash');
// No welcome onboarding for the agents.
await configManager.updateValue('pendingWelcomeOnboarding', () => false);

// The config watcher keeps the process alive, so exit explicitly.
process.exit(0);
