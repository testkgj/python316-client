const http = require('http');
const { WebSocketServer } = require('ws');

const PORT = Number(process.argv[2] || 0);
let version = null;

const server = http.createServer((req, res) => {
    if (req.url.startsWith('/json')) {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify([{
            id: 'P1', type: 'page', title: 'Discord',
            url: 'https://discord.com/channels/@me',
            webSocketDebuggerUrl: `ws://127.0.0.1:${PORT}/devtools/page/P1`
        }]));
        return;
    }
    res.statusCode = 404;
    res.end('x');
});

const wss = new WebSocketServer({ server });
wss.on('connection', (ws) => {
    ws.on('message', (raw) => {
        let m; try { m = JSON.parse(raw.toString()); } catch { return; }
        const e = String(m.params?.expression || '');
        let v;
        if (e.startsWith('window.__py316Repo')) {
            v = undefined;
        } else if (e.length > 1000) {
            const mm = e.match(/__version\s*=\s*['"]([^'"]+)['"]/);
            version = mm ? mm[1] : 'unknown';
            v = undefined;
        } else {
            v = JSON.stringify({ v: version, a: Date.now(), h: !!version });
        }
        ws.send(JSON.stringify({ id: m.id, result: { result: { type: typeof v, value: v } } }));
    });
});

server.listen(PORT, '127.0.0.1', () => console.log('MOCK_READY ' + PORT));
