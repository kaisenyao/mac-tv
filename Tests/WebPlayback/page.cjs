// The phone remote's page as the Mac serves it: remote.html with remote.css and remote.js inline.
const fs = require('node:fs');
const path = require('node:path');
const dir = path.join(__dirname, '../../Sources/MacTV/Features/Remote/Page');
const read = name => fs.readFileSync(path.join(dir, name), 'utf8');
const script = read('remote.js');
// Literal replacement, as RemotePage.swift does: a replacement string would read the script's `$$` and `$'`
// as patterns and corrupt it.
const html = read('remote.html')
  .replace('<link rel="stylesheet" href="remote.css">', () => '<style>\n' + read('remote.css') + '</style>')
  .replace('<script src="remote.js"></script>', () => '<script>\n' + script + '</script>');
if (!html.includes('<script>\n' + script + '</script>')) throw new Error('remote.js is not inlined whole');
module.exports = { html, script };
