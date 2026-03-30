const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = 8765;
const STATIC_DIR = __dirname;

const MIME = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.wasm': 'application/wasm',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.ico':  'image/x-icon',
};

const server = http.createServer((req, res) => {
  // CORS proxy: /proxy/https://...
  if (req.url.startsWith('/proxy/')) {
    const targetUrl = req.url.slice('/proxy/'.length);
    if (!targetUrl) {
      res.writeHead(400);
      return res.end('Missing target URL');
    }

    let parsed;
    try {
      parsed = new URL(targetUrl);
    } catch (e) {
      res.writeHead(400);
      return res.end('Invalid URL: ' + targetUrl);
    }

    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Max-Age': '86400',
      });
      return res.end();
    }

    const client = parsed.protocol === 'https:' ? https : http;
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: req.method,
      headers: {},
    };

    // Forward content-type for POST (git smart HTTP needs this)
    if (req.headers['content-type']) {
      options.headers['content-type'] = req.headers['content-type'];
    }
    if (req.headers['accept']) {
      options.headers['accept'] = req.headers['accept'];
    }
    options.headers['user-agent'] = 'git/2.43.0';

    const proxyReq = client.request(options, (proxyRes) => {
      const headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': '*',
      };
      if (proxyRes.headers['content-type']) headers['content-type'] = proxyRes.headers['content-type'];
      
      res.writeHead(proxyRes.statusCode, headers);
      proxyRes.pipe(res);
    });

    proxyReq.on('error', (err) => {
      console.error('Proxy error:', err.message);
      res.writeHead(502);
      res.end('Proxy error: ' + err.message);
    });

    req.pipe(proxyReq);
    return;
  }

  // Static file serving
  let filePath = req.url.split('?')[0];
  if (filePath === '/') filePath = '/index.html';
  
  const fullPath = path.join(STATIC_DIR, filePath);
  // Prevent directory traversal
  if (!fullPath.startsWith(STATIC_DIR)) {
    res.writeHead(403);
    return res.end('Forbidden');
  }

  fs.readFile(fullPath, (err, data) => {
    if (err) {
      res.writeHead(404);
      return res.end('Not found');
    }
    const ext = path.extname(fullPath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
});

server.listen(PORT, () => {
  console.log(`\nziggit WASM demo: http://localhost:${PORT}`);
  console.log(`CORS proxy:       http://localhost:${PORT}/proxy/<url>\n`);
});
