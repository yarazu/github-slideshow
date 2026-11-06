/**
 * Baut die Web-Version (claude.ai) als EINE HTML-Datei: CSS und JavaScript eingebettet,
 * keine externen Ressourcen. Ausgabe: dist/raumplaner-web.html
 *
 *   npm run build:web
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'dist');

const js = await esbuild.build({
  entryPoints: [path.join(ROOT, 'public/js/web-entry.js')],
  bundle: true,
  format: 'iife',
  target: ['es2022'],
  minify: true,
  legalComments: 'none',
  charset: 'utf8',
  write: false,
});
const css = await esbuild.transform(fs.readFileSync(path.join(ROOT, 'public/css/app.css'), 'utf8'), { loader: 'css', minify: true });

const script = js.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
// Inhalt ohne <html>/<head>/<body>: claude.ai legt das Grundgerüst beim Veröffentlichen selbst an.
const html = `<title>Raumplaner</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>${css.code}</style>
<div id="app"><div class="boot">Raumplaner wird geladen …</div></div>
<div id="toasts" class="toasts" aria-live="polite"></div>
<script>${script}</script>
`;
fs.mkdirSync(OUT_DIR, { recursive: true });
const file = path.join(OUT_DIR, 'raumplaner-web.html');
fs.writeFileSync(file, html);
console.log(`Web-Version gebaut: ${path.relative(ROOT, file)} (${Math.round(html.length / 1024)} KB)`);
