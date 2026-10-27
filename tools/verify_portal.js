// 通过 Chrome DevTools Protocol 读取真实渲染页面的 DOM 事实并截图。
// 用法: node verify_portal.js <debugPort> <outPng>
const fs = require('fs');

// Windows 上 stdout 是管道时 console.log 是异步写，紧跟 process.exit 会把输出丢掉，
// 表现为"node 退出码 0 但父进程读到空字符串"（实测间歇性复现）。用同步写。
const out = (obj) => {
  try { fs.writeSync(1, JSON.stringify(obj) + '\n'); } catch (e) { /* 忽略写失败 */ }
};

(async () => {
  const [, , debugPort, outPng] = process.argv;
  if (!debugPort || !outPng) {
    out({ ok: false, error: 'usage: node verify_portal.js <debugPort> <outPng>' });
    process.exit(2);
  }

  let list;
  try {
    list = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  } catch (e) {
    out({ ok: false, error: 'cdp unreachable: ' + e.message });
    process.exit(3);
  }

  const page = list.find(t => t.type === 'page' && !String(t.url).startsWith('devtools'));
  if (!page) {
    out({ ok: false, error: 'no page target', urls: list.map(t => t.url) });
    process.exit(4);
  }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let seq = 0;
  const pending = new Map();
  const send = (method, params = {}) => new Promise(resolve => {
    const id = ++seq;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
  ws.onmessage = ev => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
  };
  await new Promise(resolve => { ws.onopen = resolve; });

  await send('Page.enable');
  await new Promise(r => setTimeout(r, 1200));

  const expression = `(() => {
    const body = document.body;
    const win = document.querySelector('.win');
    return JSON.stringify({
      title: document.title,
      url: location.href,
      textLen: (body && body.innerText ? body.innerText.trim().length : 0),
      bg: body ? getComputedStyle(body).backgroundColor : '',
      hasWin: !!win,
      winHeight: win ? Math.round(win.getBoundingClientRect().height) : 0
    });
  })()`;

  const evaluated = await send('Runtime.evaluate', { expression, returnByValue: true });
  let info = {};
  try { info = JSON.parse(evaluated.result.value); } catch (e) { info = { parseError: String(e) }; }

  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(outPng, Buffer.from(shot.data, 'base64'));
  info.bytes = fs.statSync(outPng).size;
  info.ok = true;
  out(info);
  process.exit(0);
})();
