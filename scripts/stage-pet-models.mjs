import { createRequire } from 'node:module';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const mobile = path.resolve(import.meta.dirname, '..');
const desktop = path.resolve(mobile, '../WorldlineBox');
const source = path.join(desktop, 'public', 'companion-call');
const output = path.join(mobile, 'android/app/src/debug/assets/pet-models');
const requireDesktop = createRequire(path.join(desktop, 'package.json'));
const { rolldown } = await import(pathToFileURL(requireDesktop.resolve('rolldown')));
const entry = path.join(desktop, 'src/main/companion-bot/call-models.ts');
const build = await rolldown({
  input: entry,
  platform: 'node',
  external: ['zod'],
});
try {
  const generated = await build.generate({ format: 'cjs', codeSplitting: false });
  const module = { exports: {} };
  new Function('require', 'module', 'exports', generated.output[0].code)(
    requireDesktop, module, module.exports,
  );
  const companion = 'builtin-dafeiyu';
  const { readBotCallModel } = module.exports;
  const model = await readBotCallModel(source, companion);
  if (!model) throw new Error('Could not read the desktop Live2D model.');
  const modelDir = path.posix.dirname(model.model);
  const references = JSON.parse(await readFile(path.join(source, model.model), 'utf8')).FileReferences;
  const files = new Set([
    'live2dcubismcore.min.js',
    model.model,
    model.catalog,
    model.vts,
    path.posix.join(modelDir, 'MODEL-LICENSE.txt'),
    ...[references.Moc, references.Physics, references.DisplayInfo, references.Pose, references.UserData,
      ...references.Textures, ...model.assets.expressions.map(item => item.file), ...model.assets.motions.map(item => item.file)]
      .filter(Boolean).map(file => path.posix.join(modelDir, file)),
  ].filter(Boolean));
  // Android resource packaging requires ASCII names. Rewrite references and
  // copy the original assets with lossless, deterministic filenames.
  const names = new Map([...files].sort().map((file, index) => {
    const suffix = /\.(?:[a-z]+3\.)?([a-z0-9]+)$/i.exec(file)?.[0] ?? '';
    return [file, file === 'live2dcubismcore.min.js' ? file : `model/${index}${suffix}`];
  }));
  const localModel = names.get(model.model);
  const modelPath = file => path.posix.relative('model', names.get(path.posix.join(modelDir, file)));
  const expressions = model.manifest.Expressions.map(item => ({ ...item, File: modelPath(item.File) }));
  const motions = Object.fromEntries(Object.entries(model.manifest.Motions).map(([group, items]) =>
    [group, items.map(item => ({ ...item, File: modelPath(item.File) }))]));
  const localManifest = JSON.parse(await readFile(path.join(source, model.model), 'utf8'));
  const localRefs = localManifest.FileReferences;
  for (const key of ['Moc', 'Physics', 'DisplayInfo', 'Pose', 'UserData']) {
    if (localRefs[key]) localRefs[key] = modelPath(localRefs[key]);
  }
  localRefs.Textures = references.Textures.map(modelPath);
  localRefs.Expressions = expressions;
  localRefs.Motions = motions;
  // The renderer finds parameter labels using the model3 basename.
  if (references.DisplayInfo) {
    names.set(path.posix.join(modelDir, references.DisplayInfo), localModel.replace(/\.model3\.json$/, '.cdi3.json'));
    localRefs.DisplayInfo = modelPath(references.DisplayInfo);
  }
  for (const [file, name] of names) {
    const target = path.join(output, name);
    await mkdir(path.dirname(target), { recursive: true });
    if (file === model.model) {
      await writeFile(target, JSON.stringify(localManifest));
      continue;
    }
    const original = path.join(source, file);
    if (/\.(moc3|png)$/.test(file)) {
      const { size } = await stat(original);
      if (size < 500) throw new Error(`Model binary is missing. Run git lfs pull in WorldlineBox (${file}).`);
    }
    await copyFile(original, target);
  }
  await writeFile(path.join(output, 'models.json'), JSON.stringify({
    [companion]: { model: localModel, manifest: { Expressions: expressions, Motions: motions },
      vts: model.vtsParameters, credits: model.assets.credits, license: names.get(path.posix.join(modelDir, 'MODEL-LICENSE.txt')) },
  }));
  console.log('Staged the desktop Live2D model for the private Android test APK.');
} finally {
  await build.close();
}
