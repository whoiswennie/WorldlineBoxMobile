import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, rmdir, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const mobile = path.resolve(import.meta.dirname, '..');
const desktop = path.resolve(mobile, '../WorldlineBox');
const source = path.join(desktop, 'public', 'companion-call');
const output = path.join(mobile, 'android/app/src/bundled/assets/pet-models');
const requireDesktop = createRequire(path.join(desktop, 'package.json'));
const { rolldown } = await import(pathToFileURL(requireDesktop.resolve('rolldown')));
const build = await rolldown({
  input: path.join(desktop, 'src/main/companion-bot/call-models.ts'),
  platform: 'node',
  external: ['zod'],
});

const models = {
  'builtin-dafeiyu': 'dafeiyu',
  'yachiyo-runami': 'yachiyo',
};
const binaryMagic = {
  '.moc3': Buffer.from('MOC3'),
  '.png': Buffer.from('89504e470d0a1a0a', 'hex'),
};
const staged = new Map();

async function readSource(file) {
  const bytes = await readFile(path.join(source, file));
  const signature = binaryMagic[path.extname(file)];
  if (signature && !bytes.subarray(0, signature.length).equals(signature)) {
    throw new Error('Invalid model binary: ' + file + '. Run git lfs pull in WorldlineBox.');
  }
  return bytes;
}

async function stageModel(readBotCallModel, companion, directory) {
  const model = await readBotCallModel(source, companion);
  if (!model?.model.startsWith(directory + '/')) throw new Error('Missing desktop model for ' + companion);
  const localManifest = JSON.parse(await readFile(path.join(source, model.model), 'utf8'));
  const references = localManifest.FileReferences;
  const assets = new Set([
    path.posix.basename(model.model),
    references.Moc, references.Physics, references.DisplayInfo, references.Pose, references.UserData,
    ...references.Textures,
    ...model.manifest.Expressions.map(item => item.File),
    ...Object.values(model.manifest.Motions).flatMap(items => items.map(item => item.File)),
    ...model.assets.expressions.map(item => item.file),
    ...model.assets.motions.map(item => item.file),
  ].filter(Boolean));
  // Keep original binaries and assign deterministic ASCII names for Android.
  const names = new Map([...assets].sort().map((file, index) => [
    file, index + (/\.(?:[a-z]+3\.)?[a-z0-9]+$/i.exec(file)?.[0] ?? ''),
  ]));
  const modelName = path.posix.basename(model.model);
  const manifestName = names.get(modelName);
  const localPath = file => {
    const name = names.get(file);
    if (!name) throw new Error('Missing reference ' + file + ' in ' + model.model);
    return name;
  };
  if (references.DisplayInfo) names.set(references.DisplayInfo, manifestName.replace(/\.model3\.json$/, '.cdi3.json'));
  const expressions = model.manifest.Expressions.map(item => ({ ...item, File: localPath(item.File) }));
  const motions = Object.fromEntries(Object.entries(model.manifest.Motions).map(([group, items]) =>
    [group, items.map(item => ({ ...item, File: localPath(item.File) }))]));
  for (const key of ['Moc', 'Physics', 'DisplayInfo', 'Pose', 'UserData']) {
    if (references[key]) references[key] = localPath(references[key]);
  }
  references.Textures = references.Textures.map(localPath);
  references.Expressions = expressions;
  references.Motions = motions;

  const fingerprint = createHash('sha256');
  function stage(file, bytes) {
    fingerprint.update(JSON.stringify([file, bytes.length])).update(bytes);
    staged.set(directory + '/' + file, bytes);
  }
  for (const [file, name] of names) {
    const bytes = file === modelName
      ? Buffer.from(JSON.stringify(localManifest))
      : await readSource(path.posix.join(directory, file));
    stage(name, bytes);
  }
  stage('license.txt', await readSource(directory + '/MODEL-LICENSE.txt'));
  return {
    model: directory + '/' + manifestName,
    cacheKey: directory + '-' + fingerprint.digest('hex'),
    manifest: { Expressions: expressions, Motions: motions },
    catalog: {
      ...model.assets,
      expressions: model.assets.expressions.map(item => ({ ...item, file: localPath(item.file) })),
      motions: model.assets.motions.map(item => ({ ...item, file: localPath(item.file) })),
      license: 'license.txt',
    },
    vts: model.vtsParameters,
    credits: model.assets.credits,
    license: directory + '/license.txt',
  };
}

try {
  const generated = await build.generate({ format: 'cjs', codeSplitting: false });
  const module = { exports: {} };
  new Function('require', 'module', 'exports', generated.output[0].code)(requireDesktop, module, module.exports);
  const { readBotCallModel } = module.exports;
  const registry = {};
  for (const [companion, directory] of Object.entries(models)) registry[companion] = await stageModel(readBotCallModel, companion, directory);
  staged.set('live2dcubismcore.min.js', await readSource('live2dcubismcore.min.js'));
  await writeFile(path.join(mobile, 'assets/portraits/yachiyo-runami.png'), await readSource('yachiyo/portrait.png'));
  for (const [file, bytes] of staged) {
    const target = path.join(output, file);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, bytes);
  }
  await writeFile(path.join(output, 'models.json'), JSON.stringify(registry));

  // Retire only files named by this generator, including the old single-model layout.
  for (const directory of ['model', ...Object.values(models)]) {
    const folder = path.join(output, directory);
    const entries = await readdir(folder, { withFileTypes: true }).catch(error => {
      if (error.code === 'ENOENT') return [];
      throw error;
    });
    for (const item of entries) {
      if (item.isFile() && /^(?:[0-9]+(?:\.[a-z0-9]+)+|license\.txt)$/i.test(item.name) &&
          !staged.has(directory + '/' + item.name)) await unlink(path.join(folder, item.name));
    }
    if (directory === 'model' && entries.length && !(await readdir(folder)).length) await rmdir(folder);
  }
  console.log('Staged DeepSeek-chan and Yachiyo for Android builds.');
} finally {
  await build.close();
}
