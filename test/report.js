// mongosh report for one conversation.
// Run as a file: prepend `const CONV='<id>';` to this script and pass it to `mongosh --quiet LibreChat <file>`
// (run.sh does this; piping through stdin puts mongosh in REPL mode and breaks on blank lines).
if (typeof CONV === 'undefined') { print('CONV is not set'); quit(1); }

const clip = (s, n, keepNl) => {
  s = (typeof s === 'string' ? s : JSON.stringify(s ?? ''));
  s = keepNl ? s.trim() : s.replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
};
const strLen = (v) => (v == null ? 0 : (typeof v === 'string' ? v : JSON.stringify(v)).length);
const textParts = (content) => (content || []).filter((p) => p.type === 'text')
  .map((p) => (typeof p.text === 'string' ? p.text : p.text?.value ?? '')).join('');

const convo = db.conversations.findOne({ conversationId: CONV });
if (!convo) { print('conversation not found: ' + CONV); quit(1); }
print(`conversation ${CONV}`);
print(`spec=${convo.spec}  model=${convo.model}  title=${convo.title}`);

const msgs = db.messages.find({ conversationId: CONV }).sort({ createdAt: 1 }).toArray();
let turn = 0;
for (const m of msgs) {
  if (m.isCreatedByUser) {
    print(`\n=== user ${++turn}  [${m.messageId}]  ${clip(m.text, 120)}`);
    if (m.files?.length) print(`    files: ${m.files.map((f) => f.filename || f.file_id).join(', ')}`);
    continue;
  }
  print(`--- assistant [${m.messageId}]  model=${m.model}  ${m.error ? 'ERROR' : ''}`);
  for (const p of m.content || []) {
    if (p.type !== 'tool_call') continue;
    const t = p.tool_call;
    print(`  ${t.name}  ${clip(t.args, 150)}  → ${strLen(t.output)}`);
    if (t.subagent_content) {
      const sub = t.subagent_content;
      const names = sub.filter((x) => x.type === 'tool_call').map((x) => x.tool_call.name);
      const lastText = textParts(sub.slice().reverse().filter((x) => x.type === 'text').slice(0, 1)) || String(t.output ?? '');
      print(`      subagent ${t.subagentIdentity?.subagentAgentId ?? '?'}  (${t.subagentIdentity?.subagentKind ?? '?'})`);
      print(`      subagent tools (${names.length}): ${names.join(', ')}`);
      print(`      subagent final: ${clip(lastText, 400)}`);
    }
  }
  if (m.attachments?.length) print(`  attachments: ${m.attachments.length} (${m.attachments.map((a) => a.filename).join(', ').slice(0, 200)})`);
  print('  FINAL:\n' + clip(textParts(m.content) || m.text, 2000, true));
}

// cost table: context x model
const rows = {};
for (const t of db.transactions.find({ conversationId: CONV }).toArray()) {
  const key = `${t.context ?? '?'}|${t.model}`;
  const r = rows[key] ||= { calls: 0, input: 0, write: 0, read: 0, output: 0, usd: 0 };
  if (t.tokenType === 'prompt') {
    r.calls++;
    // title calls carry only rawAmount; message/subagent calls split it into input/write/read
    r.input += t.inputTokens != null ? -t.inputTokens : -(t.rawAmount ?? 0);
    r.write += -(t.writeTokens ?? 0);
    r.read += -(t.readTokens ?? 0);
  } else if (t.tokenType === 'completion') {
    r.output += -(t.rawAmount ?? 0);
  }
  r.usd += -(t.tokenValue ?? 0) / 1e6;
}
const pad = (s, n) => String(s).padStart(n);
print('\ncost (context x model)');
print(`${'context'.padEnd(10)} ${'model'.padEnd(20)} ${pad('calls', 6)} ${pad('input', 9)} ${pad('write', 9)} ${pad('read', 10)} ${pad('output', 8)} ${pad('$', 8)}`);
let total = 0;
for (const k of Object.keys(rows).sort()) {
  const [ctx, mdl] = k.split('|'); const r = rows[k]; total += r.usd;
  print(`${ctx.padEnd(10)} ${mdl.padEnd(20)} ${pad(r.calls, 6)} ${pad(r.input, 9)} ${pad(r.write, 9)} ${pad(r.read, 10)} ${pad(r.output, 8)} ${pad(r.usd.toFixed(4), 8)}`);
}
print(`TOTAL $${total.toFixed(4)}`);
