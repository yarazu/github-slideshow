/**
 * NUR FÜR LOKALE TESTS: liefert die gebaute Web-Version (dist/raumplaner-web.html) mit der
 * nachgebildeten claude.ai-Laufzeit (dev/mock-claude.js) aus.
 *
 *   npm run dev:web     ->  http://localhost:3955/?user=anna   (bzw. ?user=ben, ?user=cara)
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT) || 3955;
const blobs = new Map();

const page = () => `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}body{margin:0;font:14px system-ui}img{max-width:100%}[hidden]{display:none!important}</style>
<script src="/mock-claude.js"></script></head><body>${fs.readFileSync(path.join(ROOT, 'dist/raumplaner-web.html'), 'utf8')}</body></html>`;

http
  .createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(page());
    } else if (req.method === 'GET' && url.pathname === '/mock-claude.js') {
      res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
      res.end(fs.readFileSync(path.join(ROOT, 'dev/mock-claude.js')));
    } else if (req.method === 'POST' && url.pathname === '/_blob') {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const id = crypto.randomBytes(16).toString('hex');
        blobs.set(id, { type: req.headers['content-type'] || 'application/octet-stream', data: Buffer.concat(chunks) });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ id }));
      });
    } else if (req.method === 'GET' && url.pathname.startsWith('/_blob/')) {
      const blob = blobs.get(url.pathname.slice(7));
      if (!blob) {
        res.writeHead(404);
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': blob.type });
      res.end(blob.data);
    } else {
      res.writeHead(404);
      res.end();
    }
  })
  .listen(PORT, () => console.log(`Test-Umgebung der Web-Version: http://localhost:${PORT}/?user=anna`));
