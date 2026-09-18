// calfNXT macOS — Vite config.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
//   - alias utils/bridge.ts + utils/reportViewport.ts to the port versions
//   - alias @deutschesoft/use-aux-widgets to the port React glue
//   - build.target safari16 (WKWebView on macOS 13+)
//   - outDir redirected to the CMake build tree (CALFNXT_UI_OUTDIR)
import upstreamConfig from '../calfnxt/ui/vite.config.ts';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';

const portDir = path.dirname(fileURLToPath(import.meta.url));
const upstreamUi = path.resolve(portDir, '../calfnxt/ui');
const outRoot = process.env.CALFNXT_UI_OUTDIR
  ? path.resolve(process.env.CALFNXT_UI_OUTDIR)
  : path.join(upstreamUi, 'dist');

// Port shims replace upstream sources. resolve.alias with absolute string
// patterns never matches relative importees ('./bridge'), so redirect after
// resolving the importee against its importer (symlink-safe via realpath).
const portShims = new Map<string, string>([
  [path.join(upstreamUi, 'src/utils/bridge.ts'), path.join(portDir, 'ui/aliases/bridge.ts')],
  [
    path.join(upstreamUi, 'src/utils/reportViewport.ts'),
    path.join(portDir, 'ui/aliases/reportViewport.ts'),
  ],
]);

function portShimPlugin(): Plugin {
  return {
    name: 'calfnxt-port-shims',
    enforce: 'pre',
    resolveId(source, importer) {
      if (!importer || (!source.startsWith('.') && !source.startsWith('/'))) return null;
      const base = path.resolve(path.dirname(importer), source);
      for (const candidate of [base, `${base}.ts`]) {
        let real = candidate;
        try {
          real = fs.realpathSync(candidate);
        } catch {
          /* not a file — try the next candidate */
        }
        const shim = portShims.get(candidate) ?? portShims.get(real);
        if (shim) return shim;
      }
      return null;
    },
  };
}

export default async (env: { command: string; mode: string }) => {
  const resolved =
    typeof upstreamConfig === 'function'
      ? await upstreamConfig(env as never)
      : await upstreamConfig;
  // defineConfig may wrap the result in a promise of the object.
  const base: any = await Promise.resolve(resolved);

  const pluginId = (process.env.CALFNXT_PLUGIN || '').trim();

  return {
    ...base,
    plugins: [...(base.plugins || []), portShimPlugin()],
    resolve: {
      ...(base.resolve || {}),
      alias: [
        {
          find: /^@deutschesoft\/use-aux-widgets$/,
          replacement: path.join(portDir, 'ui/react-aux/index.ts'),
        },
        // The react-aux glue lives outside the ui/ root, so bare package
        // specifiers don't resolve against node_modules. Point them at the
        // installed packages explicitly.
        {
          find: /^@deutschesoft\/awml$/,
          replacement: path.join(upstreamUi, 'node_modules/@deutschesoft/awml/src/index.pure.js'),
        },
        {
          find: /^@deutschesoft\/awml\/src\/(.*)$/,
          replacement: path.join(upstreamUi, 'node_modules/@deutschesoft/awml/src/$1'),
        },
      ],
    },
    build: {
      ...(base.build || {}),
      target: 'safari16',
      outDir: pluginId ? path.join(outRoot, 'plugins', pluginId) : outRoot,
    },
  };
};
