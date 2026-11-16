import { Live2DRenderer, createScriptTagCubismLoader } from '@soullink-emotion/live2d-pixi';
import { createCallAvatar } from '../src/renderer/companion-bot/call-avatar.ts';
import { BOT_CALL_PORTRAIT_SCALE } from '../src/renderer/companion-bot/call-presentation.ts';
import '@pixi/unsafe-eval';

const stage = document.getElementById('stage');
let renderer, avatar, lastCue, presence = 'idle', fullBody = false, frame = 0, resize, fit;

// Older locally staged model folders only carry the manifest.
async function readCatalog(model, manifest) {
  const read = async file => {
    const response = await fetch(new URL(file, new URL(model, document.baseURI)));
    if (!response.ok) throw new Error('Could not read Live2D animation');
    return response.json();
  };
  const expressions = await Promise.all((manifest?.Expressions ?? []).map(async ({ Name: name, File: file }) => ({
    name, file, params: (await read(file)).Parameters.map(item => item.Id),
  })));
  const motions = await Promise.all(Object.entries(manifest?.Motions ?? {}).flatMap(([group, clips]) => clips.map(async ({ File: file }, index) => {
    const motion = await read(file);
    return { group, index, file, name: file, duration: motion.Meta.Duration,
      params: motion.Curves.filter(item => item.Target === 'Parameter').map(item => item.Id) };
  })));
  return { expressions, motions, credits: '', license: '' };
}

function dispose() {
  cancelAnimationFrame(frame);
  resize?.disconnect();
  avatar?.dispose();
  renderer?.destroy();
  avatar = undefined;
  renderer = undefined;
}

window.startPet = async ({ model, manifest, core, vts, name, catalog }) => {
  try {
    const loadCore = createScriptTagCubismLoader(core);
    renderer = new Live2DRenderer(stage, { cubismLoader: async () => {
      await loadCore();
      for (let i = 0; i < 100; i++) {
        if (window.Live2DCubismCore?.Version?.csmGetVersion?.() > 0) return;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      throw new Error('Cubism initialization timed out');
    } });
    // Query the renderer's own context. Native Android GL can report a
    // different limit from the WebView that actually uploads the textures.
    const canvas = stage.querySelector('canvas');
    const gl = canvas.getContext('webgl2') ?? canvas.getContext('webgl') ?? canvas.getContext('experimental-webgl');
    if (!gl) throw new Error('WebGL is unavailable');
    const limit = Math.min(16384, gl.getParameter(gl.MAX_TEXTURE_SIZE));
    renderer.syncViewport(2);
    const prepared = await fetch(`prepare?limit=${limit}`);
    if (!prepared.ok) throw new Error('Could not prepare model textures');
    const parameters = await renderer.load(model, { automaticIdle: false, animations: manifest });
    catalog ??= await readCatalog(model, manifest);
    await renderer.prepareNativeAnimations(catalog.expressions.map(item => item.name), catalog.motions);
    avatar = createCallAvatar({ host: stage, renderer, parameters, catalog, modelUrl: model, name, vts });
    fit = () => {
      renderer.syncViewport(2);
      renderer.setFullBody(fullBody);
      renderer.setViewScale(fullBody ? 1 : BOT_CALL_PORTRAIT_SCALE);
      renderer.setViewOffset({ x: 0, y: fullBody ? 0 : stage.clientHeight * Math.max(0, BOT_CALL_PORTRAIT_SCALE - 1) * .48 });
      const bounds = avatar.captionHead();
      const width = stage.clientWidth, height = stage.clientHeight;
      if (bounds && width && height) window.PetStatus?.reportFigure?.(
        bounds.x / width, bounds.y / height, bounds.width / width, bounds.height / height,
      );
    };
    fit();
    const tick = () => {
      avatar.update();
      frame = requestAnimationFrame(tick);
    };
    avatar.controls.present(lastCue ?? undefined, lastCue?.text);
    avatar.controls.presence(presence);
    tick();
    // Texture upload happens when Pixi draws, after load() has returned.
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const error = gl.getError();
    if (error !== gl.NO_ERROR || gl.isContextLost()) throw new Error(`Live2D texture rendering failed (${error})`);
    resize = new ResizeObserver(fit);
    resize.observe(stage);
    console.info(`Pet model rendered at ${canvas.width}x${canvas.height} (WebGL texture limit ${limit})`);
    canvas.addEventListener('webglcontextlost', () => {
      dispose();
      window.PetStatus?.postMessage('error');
    }, { once: true });
    window.PetStatus?.postMessage('ready');
    if (avatar.controls.hasBodyShape) window.PetStatus?.postMessage('body-shape');
  } catch (error) {
    dispose();
    console.warn('Pet model:', error?.message ?? String(error));
    window.PetStatus?.postMessage('error');
  }
};

window.petCue = cue => {
  lastCue = cue;
  avatar?.controls.present(cue ?? undefined, cue?.text);
};
window.petPresence = value => {
  presence = value;
  avatar?.controls.presence(value);
};
window.petAudio = level => avatar?.controls.audio(level);
window.petBodyShape = value => avatar?.controls.bodyShape(value);
window.petFullBody = value => {
  fullBody = value;
  if (renderer) fit?.();
};
