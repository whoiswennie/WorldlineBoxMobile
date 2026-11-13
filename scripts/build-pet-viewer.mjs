import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const mobile = path.resolve(import.meta.dirname, '..');
const desktop = path.resolve(mobile, '../WorldlineBox');
const requireDesktop = createRequire(path.join(desktop, 'package.json'));
const { rolldown } = await import(pathToFileURL(requireDesktop.resolve('rolldown')));
const source = await readFile(path.join(mobile, 'scripts/pet-viewer.js'), 'utf8');
const entry = path.join(desktop, 'scripts/.worldlinebox-mobile-pet-entry.js');
const output = path.join(mobile, 'assets/pet-viewer');
await mkdir(output, { recursive: true });
const build = await rolldown({ input: entry, plugins: [{
  name: 'mobile-pet-entry', resolveId(id) { if (id === entry) return entry; },
  load(id) { if (id === entry) return source; },
}] });
const result = await build.generate({ format: 'iife', codeSplitting: false, minify: true });
await build.close();
await writeFile(path.join(output, 'viewer.js'), result.output[0].code.replace(/[^\S\r\n]+(?=\r?$)/gm, ''));
