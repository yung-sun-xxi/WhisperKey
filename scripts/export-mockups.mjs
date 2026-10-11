// Exports sections of the design file as the PNGs in docs/design/mockups.
//
// Usage: node scripts/export-mockups.mjs docs/design/dark/master-design.dc.html \
//          docs/design/mockups "Settings General=settings-general.png" ...
//
// Each "Label=file" pair names a [data-screen-label] section and the file it is written
// to. The shot is the section at device scale factor 2 with 24 pt of the board's
// background around it for the shadow; the rest of the board is hidden. Needs Google
// Chrome in /Applications and Node 22 or later (for the built-in WebSocket).
import { spawn } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
const [html, outdir, ...pairs] = process.argv.slice(2);
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const port = 9333;
const proc = spawn(chrome, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), 'cdp-'))}`, '--hide-scrollbars', '--window-size=2400,1600', 'about:blank'], { stdio: 'ignore' });
const deadline = Date.now() + 60000;
const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
while (!target) {
  if (Date.now() > deadline) { proc.kill(); throw new Error('chrome did not start'); }
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(t => t.type === 'page'); } catch { await sleep(300); }
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJS = async expr => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;
await send('Emulation.setDeviceMetricsOverride', { width: 2400, height: 1600, deviceScaleFactor: 2, mobile: false });
await send('Page.enable');
await send('Page.navigate', { url: 'file://' + resolve(html) });
await sleep(4000);
for (const pair of pairs) {
  const [label, file] = pair.split('=');
  const rect = await evalJS(`(() => {
    document.querySelectorAll('[data-export-style]').forEach(s => s.remove());
    const el = document.querySelector('[data-screen-label="${label}"]');
    if (!el) return null;
    const s = document.createElement('style'); s.setAttribute('data-export-style', '');
    s.textContent = 'html, body { background: #0E1013 !important } body * { visibility: hidden !important } [data-export-target], [data-export-target] * { visibility: visible !important }';
    document.querySelectorAll('[data-export-target]').forEach(n => n.removeAttribute('data-export-target'));
    el.setAttribute('data-export-target', ''); document.head.appendChild(s);
    const r = el.getBoundingClientRect();
    return { x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height };
  })()`);
  if (!rect) { console.log('missing', label); continue; }
  const m = 24;
  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: rect.x - m, y: rect.y - m, width: rect.w + 2 * m, height: rect.h + 2 * m, scale: 1 } });
  writeFileSync(join(outdir, file), Buffer.from(shot.result.data, 'base64'));
  console.log('wrote', file, Math.round(rect.w), 'x', Math.round(rect.h));
}
ws.close(); proc.kill();
