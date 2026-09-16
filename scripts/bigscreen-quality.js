// Set Bigscreen Remote Desktop's stream size, bitrate and frame rate.
//
//   node bigscreen-quality.js <height> <mbps> <fps>
//   node bigscreen-quality.js 1440 60 30     1440 lines, 60 Mbps, 30 fps
//   node bigscreen-quality.js 1080 5 72      Bigscreen's stock setting
//
// WHY. The headset's quality menu stops at 1080p, but the PC app accepts a
// stream height from 16 to 4320 lines, 0.5 to 100 Mbps, and 1 to 300 fps. The
// headset normally changes these through a local web API that needs a pairing
// id held only in memory. Instead, Bigscreen is started with --inspect (bound to
// 127.0.0.1 only) and this script calls the same setters through its debugger.
// Nothing on disk is modified; closing Bigscreen undoes it.
//
// Run it while a stream is active - the encoder only exists then.
//
// FRAME RATE. Bigscreen encodes H.264 only. H.264 levels cap the macroblocks per
// second a decoder must handle: 4K at 30 fps fits level 5.1, 4K at 72 fps fits
// no level up to 5.2, and headset decoders may refuse it.

const height = parseInt(process.argv[2] || '1440', 10);
const mbps = parseFloat(process.argv[3] || '60');
const fps = parseInt(process.argv[4] || '30', 10);
const port = 9229;

async function main() {
  let targets;
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  } catch {
    console.log(`  No debugger on port ${port}. Start Bigscreen with "Start VR Stream.bat".`);
    process.exit(1);
  }
  const t = targets.find(x => x.type === 'node') || targets[0];
  if (!t) { console.log('  Debugger is up but lists no target.'); process.exit(1); }

  const ws = new WebSocket(t.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  ws.onmessage = ev => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  };
  const call = (method, params) => new Promise(res => {
    const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id: n, method, params }));
  });
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

  // Find the module exporting the setters, wherever the app loaded it from.
  const expr = `(() => {
    const req = (typeof require === 'function') ? require : process.mainModule.require;
    const cache = req.cache || process.mainModule.constructor._cache;
    for (const k of Object.keys(cache)) {
      const e = cache[k] && cache[k].exports;
      if (e && typeof e.SetResolution === 'function' && typeof e.SetBitrate === 'function') {
        e.SetBitrate(${Math.round(mbps * 1e6)});
        if (typeof e.SetFPS === 'function') e.SetFPS(${fps});
        e.SetResolution(${height});
        return 'applied';
      }
    }
    return 'NOT FOUND - this Bigscreen version does not expose SetResolution';
  })()`;
  const r = await call('Runtime.evaluate', { expression: expr, includeCommandLineAPI: true, returnByValue: true });
  if (r.result && r.result.exceptionDetails) {
    console.log('  Bigscreen refused:', r.result.exceptionDetails.exception?.description || r.result.exceptionDetails.text);
    process.exitCode = 1;
  } else {
    console.log(`  ${height} lines, ${mbps} Mbps, ${fps} fps: ${r.result?.result?.value}`);
  }
  ws.close();
}
main();
