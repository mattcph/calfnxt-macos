#!/usr/bin/env node
// calfNXT macOS — per-plugin UI build (Vite + flatten).
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// Runs one Vite production build for CALFNXT_PLUGIN using the port config,
// then flattens to <outDir>/{index.html,assets/}.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const portDir = path.resolve(__dirname, '..');
const upstreamUi = path.resolve(portDir, '../calfnxt/ui');

const id = (process.env.CALFNXT_PLUGIN || '').trim();
if (!id) {
  console.error('build-plugin-ui: CALFNXT_PLUGIN not set');
  process.exit(1);
}
const outRoot = process.env.CALFNXT_UI_OUTDIR
  ? path.resolve(process.env.CALFNXT_UI_OUTDIR)
  : path.join(upstreamUi, 'dist');
const config = process.env.CALFNXT_VITE_CONFIG
  ? path.resolve(process.env.CALFNXT_VITE_CONFIG)
  : path.join(portDir, 'vite.config.port.ts');

const pluginDist = path.join(outRoot, 'plugins', id);

/** Point script/link hrefs at ./assets/… for a flat Resources layout. */
function flattenAssetUrls(html) {
  return html
    .replace(/(href|src)="[^"]*\/assets\//g, '$1="./assets/')
    .replace(/(href|src)="assets\//g, '$1="./assets/')
    .replace(/<link[^>]*rel="modulepreload"[^>]*>\s*/gi, '');
}

/** First paint is black before the SPA CSS/JS arrives (avoids white flash). */
function ensureBlackSplash(html) {
  let out = html;
  if (!/html,body\{[^}]*background\s*:\s*#000/i.test(out)) {
    out = out.replace(
      /<head(\s[^>]*)?>/i,
      (m) =>
        `${m}<style>html,body{background:#000;margin:0}#root{background:#000;min-height:100%}</style>`,
    );
  }
  if (!/<div id="root"[^>]*style=/i.test(out)) {
    out = out.replace(
      /<div id="root"><\/div>/i,
      '<div id="root" style="background:#000;min-height:100%"></div>',
    );
  }
  return out;
}

function findBuiltHtml(dir, pluginId) {
  for (const p of [
    path.join(dir, 'src', 'html', `${pluginId}.html`),
    path.join(dir, `${pluginId}.html`),
    path.join(dir, 'index.html'),
  ]) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error(`Built HTML not found for "${pluginId}" under ${dir}`);
}

fs.rmSync(pluginDist, { recursive: true, force: true });

const r = spawnSync(
  'npx',
  ['vite', 'build', '--config', config],
  {
    cwd: upstreamUi,
    env: { ...process.env, CALFNXT_PLUGIN: id },
    stdio: 'inherit',
    shell: false,
  },
);
if (r.status !== 0) process.exit(r.status ?? 1);

// Flatten nested html → index.html at the pack root.
const htmlSrc = findBuiltHtml(pluginDist, id);
const html = ensureBlackSplash(flattenAssetUrls(fs.readFileSync(htmlSrc, 'utf8')));
fs.writeFileSync(path.join(pluginDist, 'index.html'), html);
const nested = path.join(pluginDist, 'src');
if (fs.existsSync(nested)) fs.rmSync(nested, { recursive: true, force: true });

const assets = fs.existsSync(path.join(pluginDist, 'assets'))
  ? fs.readdirSync(path.join(pluginDist, 'assets')).filter((n) => !n.startsWith('.'))
  : [];
console.log(`build-plugin-ui: ${id} → ${assets.length} asset(s) in ${pluginDist}`);
