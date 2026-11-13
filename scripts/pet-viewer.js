import { Live2DRenderer, createScriptTagCubismLoader } from '@soullink-emotion/live2d-pixi';
import { SoullinkRuntime } from '@soullink-emotion/engine';
import { BotCallPerformance } from '../src/renderer/companion-bot/call-performance.ts';
import { BOT_CALL_PORTRAIT_SCALE, botCallProfile } from '../src/renderer/companion-bot/call-presentation.ts';
import '@pixi/unsafe-eval';

const stage = document.getElementById('stage');
let renderer, performanceState, lastCue, sequence = 0, neutral;
window.startPet = async ({ model, manifest, core, vts, name }) => {
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
    const parameters = await renderer.load(model, { automaticIdle: true, animations: manifest });
    const clock = () => performance.now() / 1000;
    const profile = botCallProfile(parameters, model, name, vts);
    performanceState = new BotCallPerformance(new SoullinkRuntime({ profile }), clock);
    const fit = () => {
      renderer.syncViewport(2);
      renderer.setViewScale(BOT_CALL_PORTRAIT_SCALE);
      renderer.setViewOffset({ x: 0, y: stage.clientHeight * Math.max(0, BOT_CALL_PORTRAIT_SCALE - 1) * .48 });
    };
    fit();
    let previous = clock();
    const tick = () => {
      if (!renderer) return;
      const now = clock();
      renderer.setParameters(performanceState.update(now, now - previous).live2dParams);
      previous = now;
      requestAnimationFrame(tick);
    };
    tick();
    if (lastCue) window.petCue(lastCue);
    // Texture upload happens when Pixi draws, after load() has returned.
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const error = gl.getError();
    if (error !== gl.NO_ERROR || gl.isContextLost()) throw new Error(`Live2D texture rendering failed (${error})`);
    new ResizeObserver(fit).observe(stage);
    stage.addEventListener('pointermove', ({ clientX, clientY }) => performanceState.point(clientX / stage.clientWidth * 2 - 1, clientY / stage.clientHeight * 2 - 1));
    stage.addEventListener('pointerleave', () => performanceState.leave());
    console.info(`Pet model rendered at ${canvas.width}x${canvas.height} (WebGL texture limit ${limit})`);
    canvas.addEventListener('webglcontextlost', () => {
      canvas.style.visibility = 'hidden';
      window.PetStatus?.postMessage('error');
    }, { once: true });
    window.PetStatus?.postMessage('ready');
  } catch (error) {
    const failed = renderer;
    renderer = undefined;
    performanceState = undefined;
    console.warn('Pet model:', error?.message ?? String(error));
    window.PetStatus?.postMessage('error');
    failed?.destroy();
  }
};

window.petCue = cue => {
  lastCue = cue;
  const match = /^(.*):(\d+)$/.exec(cue.motion ?? '');
  clearTimeout(neutral);
  renderer?.stopNativeMotion();
  renderer?.applyNativeAnimation(null);
  performanceState?.setGesture(cue.gesture);
  performanceState?.setPresence('speaking');
  renderer?.applyNativeAnimation({
    token: ++sequence,
    expression: cue.expression ?? null,
    motion: match ? { group: match[1], index: Number(match[2]), priority: 'force' } : null,
    suppressParamIds: [],
  });
  neutral = setTimeout(() => {
    renderer?.applyNativeAnimation(null);
    performanceState?.setPresence('idle');
  }, Math.max(400, cue.durationMs ?? 3500));
};
window.petAudio = level => performanceState?.audio(level);
