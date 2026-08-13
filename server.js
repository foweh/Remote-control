'use strict';
// ============================================================
//  mouse-ctrl-v3 — 零依赖服务端
//  Node 内置 http 提供静态页 + 手写 WebSocket(RFC6455)
//  鼠标执行由常驻 PowerShell 驱动 (mouse.ps1) 完成
// ============================================================
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');

const PORT = parseInt(process.env.PORT || '8642', 10);
const ROOT = __dirname;
const PUBLIC = path.join(ROOT, 'public');
const DRY = process.env.DRY_RUN === '1' || process.argv.includes('--dry');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

// ---------------- LAN IP ----------------
function lanIPs() {
  const out = [];
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const it of ifs[name] || []) {
      if (it.family === 'IPv4' && !it.internal) out.push(it.address);
    }
  }
  // 排序：真实局域网地址优先；链路本地(169.254.x.x，手机访问不到)排最后
  const score = (ip) => {
    if (ip.startsWith('169.254.')) return 999; // 链路本地 / 虚拟网卡
    if (ip.startsWith('192.168.')) return 0;  // 最常见家用局域网
    if (ip.startsWith('10.')) return 1;
    if (ip.startsWith('172.')) return 2;
    return 10;                                 // 公网 IP 排后
  };
  out.sort((a, b) => score(a) - score(b));
  return out;
}

// ---------------- 静态文件 + /info ----------------
const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/') {
    // 手机访问根地址 → 直接跳到控制页（手机上不显示电脑端的二维码页）
    const ua = String(req.headers['user-agent'] || '').toLowerCase();
    if (/android|iphone|ipad|ipod|mobile|harmony/i.test(ua)) {
      res.writeHead(302, { Location: '/control.html' });
      res.end();
      return;
    }
  }
  if (url === '/info') {
    const body = JSON.stringify({ ips: lanIPs(), port: PORT, phones: phoneCount() });
    res.writeHead(200, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' });
    res.end(body);
    return;
  }
  let filePath = url === '/' ? '/index.html' : url;
  const abs = path.normalize(path.join(PUBLIC, filePath));
  if (!abs.startsWith(PUBLIC)) { res.writeHead(403); res.end('Forbidden'); return; }
  fs.readFile(abs, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not Found: ' + url); return; }
    const ext = path.extname(abs).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
});

// ---------------- PowerShell 鼠标驱动桥 ----------------
let ps = null;
let psReady = false;
let bounds = { x: 0, y: 0, w: 1920, h: 1080 };
const pendingCmds = [];
const pongQueue = []; // 等待 pong 回复的客户端（FIFO）

function startPS() {
  let p;
  try {
    p = spawn('powershell.exe',
      ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'mouse.ps1')],
      { stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (e) {
    console.error('启动 PowerShell 失败:', e.message);
    setTimeout(startPS, 2000);
    return;
  }
  ps = p;
  psReady = false;
  let buf = '';
  p.stdout.on('data', (d) => {
    buf += d.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).replace(/\r$/, '');
      buf = buf.slice(idx + 1);
      onPSLine(line);
    }
  });
  p.stderr.on('data', (d) => process.stderr.write('[mouse.ps1] ' + d));
  p.on('exit', (code) => {
    ps = null;
    psReady = false;
    for (const c of clients) stopScroll(c, true);
    console.log(`[mouse.ps1 退出 code=${code}] 1.5 秒后自动重启...`);
    setTimeout(startPS, 1500);
  });
}

function onPSLine(line) {
  const t = line.trim();
  if (line.startsWith('B ')) {
    const p = line.split(/\s+/);
    bounds = { x: +p[1], y: +p[2], w: +p[3], h: +p[4] };
    console.log(`[鼠标驱动] 虚拟屏幕 ${bounds.w}x${bounds.h} @(${bounds.x},${bounds.y})`);
    // 驱动晚于手机连接时，把真实边界推送给已连接的手机
    for (const c of clients) {
      if (c.page === 'control' || c.page === 'scroll') sendJSON(c, { t: 'bounds', ...bounds });
    }
  } else if (t === 'READY') {
    psReady = true;
    console.log('[鼠标驱动] 就绪');
    while (pendingCmds.length) mouseCmd(pendingCmds.shift());
  } else if (t === 'OK') {
    const c = pongQueue.shift();
    if (c && c.sock) sendJSON(c, { t: 'pong', ts: c.pingTs });
  }
}

// 低层指令发送：驱动未就绪时丢弃移动/滚轮（避免回放陈旧坐标），排队点击/键盘
function mouseCmd(s) {
  if (DRY) {
    if (s === 'P') onPSLine('OK');
    else console.log('[dry]', s);
    return;
  }
  if (ps && psReady) {
    try { ps.stdin.write(s + '\n'); } catch (e) { console.error('写入驱动失败:', e.message); }
  } else if (/^[LK]|^P$/.test(s)) {
    if (pendingCmds.length < 100) pendingCmds.push(s);
  }
}

// ---------------- WebSocket（手写 RFC6455） ----------------
const MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const clients = new Set();

function sendJSON(c, obj) {
  const payload = Buffer.from(JSON.stringify(obj), 'utf8');
  let header;
  if (payload.length < 126) {
    header = Buffer.alloc(2);
    header[1] = payload.length;
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  header[0] = 0x81; // FIN + text
  try { c.sock.write(Buffer.concat([header, payload])); } catch (e) {}
}

function broadcast(obj, filter) {
  for (const c of clients) if (!filter || filter(c)) sendJSON(c, obj);
}

function phoneCount() {
  let n = 0;
  for (const c of clients) if (c.page === 'control' || c.page === 'scroll') n++;
  return n;
}

function notifyPC() {
  const phones = [];
  for (const c of clients) {
    if (c.page === 'control' || c.page === 'scroll') phones.push({ page: c.page });
  }
  broadcast({ t: 'clients', n: phones.length, phones }, (c) => c.page === 'index');
}

function parseFrames(c) {
  const st = c.wsState;
  for (;;) {
    const buf = st.buf;
    if (buf.length < 2) return;
    const b0 = buf[0], b1 = buf[1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let off = 2;
    if (len === 126) {
      if (buf.length < 4) return;
      len = buf.readUInt16BE(2);
      off = 4;
    } else if (len === 127) {
      if (buf.length < 10) return;
      len = Number(buf.readBigUInt64BE(2));
      off = 10;
    }
    const maskLen = masked ? 4 : 0;
    if (buf.length < off + maskLen + len) return;
    let payload = Buffer.from(buf.subarray(off + maskLen, off + maskLen + len));
    if (masked) {
      const key = buf.subarray(off, off + 4);
      for (let i = 0; i < payload.length; i++) payload[i] ^= key[i & 3];
    }
    st.buf = buf.subarray(off + maskLen + len);

    if (opcode === 0x8) { try { c.sock.end(); } catch (e) {} return; }
    if (opcode === 0x9) { // ping -> pong
      const p = Buffer.alloc(2 + payload.length);
      p[0] = 0x8a;
      p[1] = payload.length;
      payload.copy(p, 2);
      try { c.sock.write(p); } catch (e) {}
      continue;
    }
    if (opcode === 0xa) continue; // pong
    // 文本帧（含分片续帧）
    if (opcode === 0x1 || opcode === 0x0) {
      st.frag = (opcode === 0x1 || !st.frag) ? payload : Buffer.concat([st.frag, payload]);
      if (fin) {
        const msg = st.frag;
        st.frag = null;
        try { handleMessage(c, JSON.parse(msg.toString('utf8'))); } catch (e) {}
      }
    }
  }
}

function handleMessage(c, m) {
  if (!m || typeof m.t !== 'string') return;
  switch (m.t) {
    case 'ping':
      c.pingTs = m.ts;
      pongQueue.push(c);
      mouseCmd('P');
      break;
    case 'm': { // 绝对移动（0..1 归一化）
      const x = Math.round(bounds.x + Math.min(1, Math.max(0, +m.x || 0)) * bounds.w);
      const y = Math.round(bounds.y + Math.min(1, Math.max(0, +m.y || 0)) * bounds.h);
      mouseCmd(`M ${x} ${y}`);
      break;
    }
    case 'r': { // 相对移动
      const dx = Math.round(+m.dx || 0), dy = Math.round(+m.dy || 0);
      if (dx || dy) mouseCmd(`R ${dx} ${dy}`);
      break;
    }
    case 'lc': mouseCmd('LC'); break;
    case 'rc': mouseCmd('RC'); break;
    case 'ld': mouseCmd('LD'); break;
    case 'lu': mouseCmd('LU'); break;
    case 'rd': mouseCmd('RD'); break;
    case 'ru': mouseCmd('RU'); break;
    case 'w': { // 单次滚轮
      let d = Math.round(+m.d || 0);
      d = Math.max(-4000, Math.min(4000, d));
      if (d) mouseCmd(`W ${d}`);
      break;
    }
    case 'k': {
      const text = String(m.text || '').replace(/[\r\n]+/g, ' ').slice(0, 4000);
      if (text) mouseCmd('K ' + text);
      break;
    }
    case 'scrollStart':
      startScroll(c, m.dir === 'up' ? 'up' : 'down');
      break;
    case 'scrollStop':
      stopScroll(c);
      break;
    case 'wset': {
      c.wspeed = Math.min(10, Math.max(1, Math.round(+m.v || 3)));
      break;
    }
  }
}

// ---------------- 服务端滚轮循环（温柔丝滑：400ms 缓动入 / 100ms 渐出） ----------------
function startScroll(c, dir) {
  if (c.scroll) { // 已激活：仅切换方向、取消渐出
    c.scroll.dir = dir;
    c.scroll.out = false;
    return;
  }
  c.scroll = { dir, ramp: 0, phase: 0, out: false };
  c.scroll.timer = setInterval(() => tickScroll(c), 16);
}

function tickScroll(c) {
  const s = c.scroll;
  if (!s) return;
  if (!s.out) {
    s.ramp = Math.min(1, s.ramp + 16 / 400); // 400ms 缓动进入
  } else {
    s.ramp -= 16 / 100;                       // 100ms 渐出
    if (s.ramp <= 0) { stopScroll(c, true); return; }
  }
  const speed = (c.wspeed || 3) * s.ramp;     // 格/秒（1 格 = 120）
  s.phase += speed * 16 / 1000;
  while (s.phase >= 1) {
    s.phase -= 1;
    mouseCmd('W ' + (s.dir === 'up' ? 120 : -120));
  }
}

function stopScroll(c, hard) {
  const s = c.scroll;
  if (!s) return;
  if (!hard && !s.out && s.ramp > 0.05) { s.out = true; return; } // 先渐出
  clearInterval(s.timer);
  c.scroll = null;
}

// ---------------- HTTP upgrade -> WebSocket ----------------
server.on('upgrade', (req, sock) => {
  const url = (req.url || '').split('?')[0];
  if (url !== '/ws') { sock.destroy(); return; }
  const key = req.headers['sec-websocket-key'];
  if (!key) { sock.destroy(); return; }
  const accept = crypto.createHash('sha1').update(key + MAGIC).digest('base64');
  sock.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n'
  );

  const q = (req.url || '').split('?')[1] || '';
  const page = new URLSearchParams(q).get('page') || 'index';
  const c = {
    sock,
    page,
    wspeed: 3,
    scroll: null,
    wsState: { buf: Buffer.alloc(0), frag: null },
    pingTs: null,
  };
  clients.add(c);
  sock.on('data', (d) => { c.wsState.buf = Buffer.concat([c.wsState.buf, d]); parseFrames(c); });
  sock.on('close', () => { stopScroll(c, true); clients.delete(c); notifyPC(); });
  sock.on('error', () => { stopScroll(c, true); clients.delete(c); notifyPC(); });

  if (page === 'control' || page === 'scroll') {
    if (psReady) sendJSON(c, { t: 'bounds', ...bounds });
    console.log(`📱 手机已连接 (${page})，当前手机数: ${phoneCount()}`);
  } else {
    console.log('🖥️  PC 页面已连接');
  }
  notifyPC();
});

// ---------------- 启动 ----------------
startPS();
server.listen(PORT, '0.0.0.0', () => {
  console.log('✅ mouse-ctrl-v3 服务已启动');
  console.log(`📍 本机访问: http://localhost:${PORT}`);
  for (const ip of lanIPs()) console.log(`📱 手机访问: http://${ip}:${PORT}`);
  console.log('   扫 PC 页面上的二维码即可控制鼠标');
});
