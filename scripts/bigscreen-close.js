// Tear down Bigscreen's stream through its debugger, in the app's own order:
// capture, video and audio off, then the connections. Used by close-bigscreen.ps1.
(async () => {
  let t;
  try { t = (await (await fetch('http://127.0.0.1:9229/json/list')).json())[0]; }
  catch { console.log('no debugger'); process.exit(1); }
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  const expr = `(() => {
    const req = (typeof require === 'function') ? require : process.mainModule.require;
    const cache = req.cache || process.mainModule.constructor._cache;
    for (const k of Object.keys(cache)) {
      const e = cache[k] && cache[k].exports;
      if (e && typeof e.ShutdownRemoteDesktop === 'function') {
        try {
          e.ShutdownRemoteDesktop();
          if (e.ShutdownDesktopConnections) e.ShutdownDesktopConnections();
          return 'stream torn down';
        } catch (err) { return 'stream teardown threw: ' + err.message; }
      }
    }
    return 'stream control not found';
  })()`;
  ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, includeCommandLineAPI: true, returnByValue: true } }));
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id !== 1) return;
    console.log(m.result?.result?.value ?? JSON.stringify(m.result));
    ws.close();
  };
})();
