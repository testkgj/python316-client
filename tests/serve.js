const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = process.argv[2];
const PORT = Number(process.argv[3] || 0);
const ABS = path.resolve(ROOT);

http.createServer((req, res) => {
    const name = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '');
    const file = path.resolve(path.join(ABS, name));
    if (!file.startsWith(ABS)) { res.statusCode = 403; return res.end('no'); }
    fs.readFile(file, (err, buf) => {
        if (err) { res.statusCode = 404; return res.end('nf'); }
        res.setHeader('Content-Type', path.extname(file) === '.json' ? 'application/json' : 'text/plain');
        res.end(buf);
    });
}).listen(PORT, '127.0.0.1', () => console.log('SERVE_READY ' + PORT));
