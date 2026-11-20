// Drives one LibreChat chat turn through the REST API (runs inside the librechat container).
// Usage: node chat.mjs --spec <name> (--text <t> | --text-file <path>) [--conv <id> --parent <msgId>]
//                      [--image <path>] [--dump <file>] [--upload-only]
//                      [--file <path> [--file-name <name>] [--file-mode provider|text]]
// --file attaches a document (PDF etc.) like the web client's attach button (POST /api/files,
// message_file=true). --file-mode provider (default): no tool_resource, the server routes the file
// (a PDF on Anthropic goes to the model as a base64 document block). --file-mode text:
// tool_resource=context ("Upload as Text"), text is extracted and sent as "Attached document(s)".
// Env: T_EMAIL, T_PASS. stdout: one JSON line {conversationId, responseMessageId, seconds, text}.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const BASE = 'http://localhost:3080';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36';
const TIMEOUT_MS = 25 * 60 * 1000;
const ROOT_PARENT = '00000000-0000-0000-0000-000000000000';
const require = createRequire('/app/api/package.json'); // resolves js-yaml, sharp from the app's node_modules

const log = (...a) => console.error(...a);
const die = (msg) => { console.error('ERROR: ' + msg); process.exit(1); };

// ---- args ----
const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith('--')) die('unexpected arg ' + argv[i]);
  const k = argv[i].slice(2);
  args[k] = (k === 'upload-only') ? true : argv[++i];
}
if (!args.spec) die('--spec is required');
let text = args.text ?? (args['text-file'] ? fs.readFileSync(args['text-file'], 'utf8') : null);
if (text == null && !args['upload-only']) die('--text or --text-file is required');
const FILE_MODE = args['file-mode'] ?? 'provider';
if (!['provider', 'text'].includes(FILE_MODE)) die('--file-mode must be provider or text');
if (args['file-mode'] && !args.file) die('--file-mode requires --file');
if (args['file-name'] && !args.file) die('--file-name requires --file');
if (args.conv && !args.parent) die('--conv requires --parent (previous responseMessageId)');
if (!process.env.T_EMAIL || !process.env.T_PASS) die('T_EMAIL / T_PASS not set');

// ---- spec -> endpoint/model ----
const yaml = require('js-yaml');
const cfg = yaml.load(fs.readFileSync('/app/librechat.yaml', 'utf8'));
// A name starting with agent_ is a saved agent, chatted with directly (no spec).
const AGENT = args.spec.startsWith('agent_') ? args.spec : null;
const spec = AGENT ? { name: AGENT, preset: { endpoint: 'agents', model: AGENT } }
  : (cfg.modelSpecs?.list || []).find((s) => s.name === args.spec);
if (!spec) die(`spec "${args.spec}" not found; have: ${(cfg.modelSpecs?.list || []).map((s) => s.name).join(', ')}`);
const { endpoint, model } = spec.preset;

// ---- auth (token lives ~15 min; re-login on 401) ----
// The token is kept in the container between runs: LibreChat limits logins (~7 per 5 minutes).
const TOKEN_FILE = '/tmp/parley-token';
let token = fs.existsSync(TOKEN_FILE) ? fs.readFileSync(TOKEN_FILE, 'utf8').trim() || null : null;
async function login() {
  const r = await fetch(BASE + '/api/auth/login', {
    method: 'POST',
    headers: { 'user-agent': UA, 'content-type': 'application/json' },
    body: JSON.stringify({ email: process.env.T_EMAIL, password: process.env.T_PASS }),
  });
  if (!r.ok) die(`login failed: HTTP ${r.status}`);
  token = (await r.json()).token;
  fs.writeFileSync(TOKEN_FILE, token, { mode: 0o600 });
}
// fetch with auth; one re-login retry on 401. `init.body` must be re-usable (string / FormData).
async function api(url, init = {}) {
  const go = () => fetch(BASE + url, {
    ...init,
    headers: { 'user-agent': UA, authorization: 'Bearer ' + token, ...(init.headers || {}) },
  });
  let r = await go();
  if (r.status === 401) { await login(); r = await go(); }
  return r;
}

// ---- image upload (same call as the web client: POST /api/files/images, multipart) ----
const MIME = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' };
async function uploadImage(p) {
  const buf = fs.readFileSync(p);
  const name = path.basename(p);
  const mime = MIME[path.extname(p).toLowerCase()] || 'application/octet-stream';
  const { width, height } = await require('sharp')(buf).metadata();
  const form = new FormData(); // field order follows the client
  form.append('endpoint', endpoint);
  form.append('file', new Blob([buf], { type: mime }), encodeURIComponent(name));
  form.append('file_id', crypto.randomUUID());
  form.append('width', String(width));
  form.append('height', String(height));
  form.append('message_file', 'true');
  const r = await api('/api/files/images', { method: 'POST', body: form });
  const body = await r.text();
  if (!r.ok) die(`image upload failed: HTTP ${r.status} ${body.slice(0, 300)}`);
  let f;
  try { f = JSON.parse(body); } catch { die('image upload: non-JSON response: ' + body.slice(0, 300)); }
  log(`uploaded ${name}: file_id=${f.file_id} ${f.width}x${f.height}`);
  return f;
}

// ---- document upload (same call as the web client's attach button: POST /api/files, multipart) ----
// Unified upload UX (default; fileConfig has no legacyFileUploadUX): one attach button, no menu, so no
// tool_resource is sent and the server decides the delivery path (PDF on anthropic -> "provider").
// The legacy menu items map to tool_resource: "Upload as Text" -> context; file_search / execute_code
// are not usable here (interface.fileSearch/runCode are off, no RAG API).
const DOC_MIME = {
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown', '.csv': 'text/csv',
  '.json': 'application/json', '.html': 'text/html', '.xml': 'application/xml',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};
async function uploadDocument(p, displayName) {
  const buf = fs.readFileSync(p);
  const name = displayName || path.basename(p);
  const mime = DOC_MIME[path.extname(name).toLowerCase()] || DOC_MIME[path.extname(p).toLowerCase()] || 'application/octet-stream';
  const form = new FormData(); // field order follows the client (hooks bundle, fe())
  form.append('endpoint', endpoint);
  form.append('endpointType', '');
  form.append('file', new Blob([buf], { type: mime }), encodeURIComponent(name));
  form.append('file_id', crypto.randomUUID());
  if (args.conv) form.append('conversationId', args.conv); // the client adds it once the conversation exists
  form.append('message_file', 'true');
  if (FILE_MODE === 'text') form.append('tool_resource', 'context');
  if (AGENT) form.append('agent_id', AGENT);
  const r = await api('/api/files', { method: 'POST', body: form });
  const body = await r.text();
  if (!r.ok) die(`file upload failed: HTTP ${r.status} ${body.slice(0, 300)}`);
  let f;
  try { f = JSON.parse(body); } catch { die('file upload: non-JSON response: ' + body.slice(0, 300)); }
  log(`uploaded ${name} (${mime}, mode=${FILE_MODE}): file_id=${f.file_id} type=${f.type} bytes=${f.bytes} source=${f.source} llmDeliveryPath=${f.llmDeliveryPath}` +
    (typeof f.text === 'string' ? ` text=${f.text.length} chars` : ''));
  return f;
}
// The entry the web client puts into the message body (useChatFunctions: file_id, filepath, filename,
// type, llmDeliveryPath, height, width) once the upload finished; the server re-reads the record by file_id.
const docBodyEntry = (f) => ({
  file_id: f.file_id, filepath: f.filepath, filename: f.filename, type: f.type ?? '',
  llmDeliveryPath: f.llmDeliveryPath, height: f.height, width: f.width,
});

// ---- SSE reader: yields {event, data} blocks ----
async function* sse(res) {
  const dec = new TextDecoder();
  let buf = '';
  for await (const chunk of res.body) {
    buf += dec.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const block = buf.slice(0, i); buf = buf.slice(i + 2);
      let event = 'message'; const data = [];
      for (const line of block.split('\n')) {
        if (line.startsWith('event:')) event = line.slice(6).trim();
        else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
      }
      if (!data.length) continue;
      const raw = data.join('\n');
      let json = null;
      try { json = JSON.parse(raw); } catch { /* keep raw */ }
      yield { event, raw, json };
    }
  }
}

const textOf = (content) => (content || [])
  .filter((p) => p.type === 'text')
  .map((p) => (typeof p.text === 'string' ? p.text : p.text?.value ?? ''))
  .join('');

// ---- main ----
if (!token) await login();
const files = [];
if (args.image) files.push(await uploadImage(args.image));
const docFiles = [];
if (args.file) {
  const f = await uploadDocument(args.file, args['file-name']);
  docFiles.push(f);
  log('message body files entry: ' + JSON.stringify(docBodyEntry(f)));
}
if (args['upload-only']) { console.log(JSON.stringify(files[0] ?? docFiles[0])); process.exit(0); }

const t0 = Date.now();
const body = {
  text, endpoint,
  // The web client sends the spec preset fields too (maxContextTokens, thinking, ...).
  ...(AGENT ? { agent_id: AGENT } : { ...spec.preset, spec: spec.name, model }),
  conversationId: args.conv || null,
  parentMessageId: args.parent || ROOT_PARENT,
  messageId: crypto.randomUUID(),
  isCreatedByUser: true, sender: 'User',
};
if (files.length || docFiles.length) {
  body.files = [
    ...files.map((f) => ({
      file_id: f.file_id, type: f.type, filepath: f.filepath, height: f.height, width: f.width,
      filename: f.filename, source: f.source, embedded: f.embedded, llmDeliveryPath: f.llmDeliveryPath,
    })),
    ...docFiles.map(docBodyEntry),
  ];
}
const post = await api('/api/agents/chat/' + endpoint, {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
});
const postText = await post.text();
if (!post.ok) die(`POST chat failed: HTTP ${post.status} ${postText.slice(0, 500)}`);
const { streamId, conversationId } = JSON.parse(postText);
log(`conv=${conversationId} spec=${spec.name} model=${model}`);

const dump = args.dump ? fs.createWriteStream(args.dump) : null;
const seenTools = new Set();
let final = null, error = null;
const deadline = t0 + TIMEOUT_MS;

// the stream is resumable: if it drops before the final event, re-attach (a few times)
for (let attempt = 0; attempt < 4 && !final && !error && Date.now() < deadline; attempt++) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), Math.max(1, deadline - Date.now()));
  try {
    const res = await api('/api/agents/chat/stream/' + streamId, { signal: ac.signal });
    if (!res.ok) die(`stream failed: HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
    for await (const ev of sse(res)) {
      dump?.write(`event: ${ev.event}\ndata: ${ev.raw}\n\n`);
      const d = ev.json;
      if (ev.event === 'error') { error = d?.error?.message ?? d?.message ?? ev.raw.slice(0, 500); break; }
      if (!d) continue;
      if (d.error && !d.final) { error = typeof d.error === 'string' ? d.error : JSON.stringify(d.error).slice(0, 500); break; }
      if (d.final || d.responseMessage) { final = d; }
      // tool starts: on_run_step with tool_calls details
      if (d.event === 'on_run_step') {
        for (const tc of d.data?.stepDetails?.tool_calls ?? []) {
          if (tc.id && !seenTools.has(tc.id) && tc.name) { seenTools.add(tc.id); log(`  tool: ${tc.name}`); }
        }
      }
    }
  } catch (e) {
    if (e.name === 'AbortError') die('timeout after 25 minutes');
    log(`stream interrupted (${e.message}); re-attaching`);
  } finally { clearTimeout(timer); }
}
dump?.end();
if (error) die(error);

let msg = final?.responseMessage;
if (!msg) { // fallback: read the saved assistant message from the API
  log('no final event on stream; reading messages from the API');
  const r = await api('/api/messages/' + conversationId);
  const list = r.ok ? await r.json() : [];
  msg = [...(Array.isArray(list) ? list : list.messages || [])].reverse().find((m) => !m.isCreatedByUser);
  if (!msg) die('no response message found');
}
if (msg.error) die('response flagged as error: ' + (textOf(msg.content) || msg.text || '').slice(0, 500));
console.log(JSON.stringify({
  conversationId: msg.conversationId ?? conversationId,
  responseMessageId: msg.messageId,
  seconds: Math.round((Date.now() - t0) / 100) / 10,
  text: textOf(msg.content) || msg.text || '',
}));
