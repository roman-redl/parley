// mongosh dump of the last assistant reply of a conversation, part by part, in order:
// tool calls, think and text parts (subagent parts are indented under their call).
// Run as a file: prepend `const CONV='<id>';` and pass it to `mongosh --quiet LibreChat <file>`
// (run.sh --steps does this).
if (typeof CONV === 'undefined') { print('CONV is not set'); quit(1); }

const oneLine = (v, n) => {
  const s = (typeof v === 'string' ? v : JSON.stringify(v ?? '')).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '…' : s;
};
const textOf = (p) => (typeof p.text === 'string' ? p.text : p.text?.value ?? '');

const dump = (parts, indent) => (parts || []).forEach((p, i) => {
  const pre = `${indent}${i} `;
  if (p.type === 'tool_call') {
    print(`${pre}CALL  ${p.tool_call.name}  ${oneLine(p.tool_call.args, 100)}`);
    if (p.tool_call.subagent_content) dump(p.tool_call.subagent_content, indent + '    ');
  } else if (p.type === 'think') print(`${pre}THINK ${oneLine(p.think, 400)}`);
  else if (p.type === 'text') print(`${pre}TEXT  ${oneLine(textOf(p), 700)}`);
  else print(`${pre}${p.type}  ${oneLine(p, 300)}`);
});

const m = db.messages.find({ conversationId: CONV, isCreatedByUser: false })
  .sort({ createdAt: -1 }).limit(1).toArray()[0];
if (!m) { print('no assistant message in conversation: ' + CONV); quit(1); }
print(`message ${m.messageId}  model=${m.model}`);
dump(m.content, '');
print(`error: ${m.error}  unfinished: ${m.unfinished}`);
