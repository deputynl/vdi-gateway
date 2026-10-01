// vdi-gateway: plays the remote desktop's audio. vdi-audio-server streams raw
// PCM (s16le, 48 kHz, stereo) over a WebSocket on /vdi-audio, which the
// reverse proxy routes to AUDIO_PORT.
(() => {
    "use strict";
    const RATE = 48000;
    const url = `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/vdi-audio`;
    let ctx, node, retry = 1000;

    function connect() {
        const ws = new WebSocket(url);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => { retry = 1000; };
        ws.onmessage = (e) => node.port.postMessage(e.data, [e.data]);
        ws.onclose = () => {
            setTimeout(connect, retry);
            retry = Math.min(retry * 2, 30000);
        };
    }

    // Browsers keep an AudioContext suspended until a user gesture.
    function resume() {
        if (ctx && ctx.state !== "running") ctx.resume();
    }

    async function init() {
        ctx = new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
        await ctx.audioWorklet.addModule("./vdi-audio-worklet.js");
        node = new AudioWorkletNode(ctx, "vdi-audio", { outputChannelCount: [2] });
        node.connect(ctx.destination);
        // Capture phase: KasmVNC's canvas stops propagation of its events.
        for (const type of ["pointerdown", "keydown", "touchstart"]) {
            window.addEventListener(type, resume, true);
        }
        connect();
    }

    init().catch((e) => console.error("vdi-audio:", e));
})();
