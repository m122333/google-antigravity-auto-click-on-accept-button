'use strict';

const fs = require('fs');
const path = require('path');

const DEBUG_PORT_KEY = 'remote-debugging-port';

function tokenize(text) {
  const tokens = [];
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      const start = i++;
      while (i < text.length && text[i] !== '"') i += text[i] === '\\' ? 2 : 1;
      tokens.push({ type: 'string', start, end: ++i });
    } else if (ch === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
    } else if (ch === '/' && text[i + 1] === '*') {
      const close = text.indexOf('*/', i + 2);
      i = close === -1 ? text.length : close + 2;
    } else if (/\s/.test(ch)) {
      i++;
    } else if ('{}[]:,'.includes(ch)) {
      tokens.push({ type: ch, start: i, end: ++i });
    } else {
      const start = i;
      while (i < text.length && !/[\s{}[\]:,"/]/.test(text[i])) i++;
      if (i === start) i++;
      tokens.push({ type: 'literal', start, end: i });
    }
  }
  return tokens;
}

function parse(text) {
  const tokens = tokenize(text);
  const json = tokens
    .filter((token, i) => {
      const next = tokens[i + 1];
      return !(token.type === ',' && next && (next.type === '}' || next.type === ']'));
    })
    .map((token) => text.slice(token.start, token.end))
    .join('');
  return json ? JSON.parse(json) : {};
}

function findProperty(text, tokens, key) {
  let depth = 0;
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.type === '{' || token.type === '[') {
      depth++;
    } else if (token.type === '}' || token.type === ']') {
      depth--;
    } else if (
      depth === 1 &&
      token.type === 'string' &&
      tokens[i + 1] &&
      tokens[i + 1].type === ':' &&
      JSON.parse(text.slice(token.start, token.end)) === key
    ) {
      let end = i + 2;
      let nesting = 0;
      do {
        const type = tokens[end].type;
        if (type === '{' || type === '[') nesting++;
        if (type === '}' || type === ']') nesting--;
        end++;
      } while (nesting > 0 && end < tokens.length);
      return { first: i, last: end - 1 };
    }
  }
  return null;
}

function withProperty(text, key, value) {
  const tokens = tokenize(text);
  const close = tokens[tokens.length - 1];
  if (!close || close.type !== '}') throw new Error('argv.json does not contain a JSON object');
  const previous = tokens[tokens.length - 2];
  const needsComma = previous.type !== '{' && previous.type !== ',';
  const head = text.slice(0, previous.end) + (needsComma ? ',' : '');
  const body = text.slice(previous.end, close.start).replace(/\s+$/, '');
  return `${head}${body}\n\t${JSON.stringify(key)}: ${JSON.stringify(value)}\n${text.slice(close.start)}`;
}

function withoutProperty(text, key) {
  const tokens = tokenize(text);
  const found = findProperty(text, tokens, key);
  if (!found) return text;

  const before = tokens[found.first - 1];
  const after = tokens[found.last + 1];
  let start = tokens[found.first].start;
  let end = tokens[found.last].end;
  let orphanComma = null;
  if (after && after.type === ',') end = after.end;
  else if (before && before.type === ',') orphanComma = before;

  const lineStart = text.lastIndexOf('\n', start - 1) + 1;
  const lineEnd = text.indexOf('\n', end) === -1 ? text.length : text.indexOf('\n', end);
  if (!text.slice(lineStart, start).trim() && !text.slice(end, lineEnd).trim()) {
    start = lineStart;
    end = Math.min(lineEnd + 1, text.length);
  } else if (orphanComma) {
    start = orphanComma.start;
    orphanComma = null;
  }
  const result = text.slice(0, start) + text.slice(end);
  if (!orphanComma) return result;
  return result.slice(0, orphanComma.start) + result.slice(orphanComma.end);
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function readDebugPort(file) {
  const text = readText(file);
  if (text === null) return undefined;
  const value = parse(text)[DEBUG_PORT_KEY];
  return value === undefined ? undefined : Number(value);
}

function enableDebugPort(file, port) {
  const text = readText(file) || '{\n}\n';
  if (parse(text)[DEBUG_PORT_KEY] !== undefined) return false;
  const updated = withProperty(text, DEBUG_PORT_KEY, String(port));
  parse(updated);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, updated);
  return true;
}

function disableDebugPort(file) {
  const text = readText(file);
  if (text === null || parse(text)[DEBUG_PORT_KEY] === undefined) return false;
  fs.writeFileSync(file, withoutProperty(text, DEBUG_PORT_KEY));
  return true;
}

module.exports = { readDebugPort, enableDebugPort, disableDebugPort };

if (require.main === module) {
  const [command, file, port] = process.argv.slice(2);
  try {
    if (command === 'enable') {
      enableDebugPort(file, Number(port) || 9333);
      process.stdout.write(String(readDebugPort(file)));
    } else if (command === 'disable') {
      disableDebugPort(file);
    } else if (command === 'port') {
      process.stdout.write(String(readDebugPort(file) || ''));
    } else {
      process.stderr.write('usage: argv.js enable <argv.json> [port] | disable <argv.json> | port <argv.json>\n');
      process.exit(2);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
