// vdi-gateway: remote desktop audio in the KasmVNC page. vdi-audio-server
// streams raw PCM (s16le, 48 kHz, stereo) over a WebSocket on /vdi-audio,
// which the reverse proxy routes to AUDIO_PORT. If the server enables the
// microphone, a toggle button sends the local mic back (s16le, 48 kHz, mono).
(() => {
    "use strict";
    const RATE = 48000;
    const url = `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/vdi-audio`;
    // The page loads this script as vdi-audio.js?v=<hash>; reuse the hash so
    // a cached worklet from an older image is never paired with this script.
    const worklet = `./vdi-audio-worklet.js${new URL(document.currentScript.src).search}`;
    let ctx, node, ws, retry = 1000;
    let button, mic = null; // mic: {ctx, stream} while the microphone is on

    function connect() {
        ws = new WebSocket(url);
        ws.binaryType = "arraybuffer";
        ws.onopen = () => { retry = 1000; };
        ws.onmessage = (e) => {
            if (typeof e.data === "string") configure(JSON.parse(e.data));
            else node.port.postMessage(e.data, [e.data]);
        };
        ws.onclose = () => {
            setTimeout(connect, retry);
            retry = Math.min(retry * 2, 30000);
        };
    }

    function configure(settings) {
        if (settings.mic && !button) addMicButton();
    }

    // Browsers keep an AudioContext suspended until a user gesture.
    function resume() {
        if (ctx && ctx.state !== "running") ctx.resume();
    }

    async function startMic() {
        const stream = await navigator.mediaDevices.getUserMedia({
            // Echo cancellation keeps the remote audio, played on the local
            // speakers, from being sent back to the remote desktop.
            audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        });
        // A context at the device's own rate: Firefox can't connect a mic to
        // a context running at another rate. The worklet resamples to 48 kHz.
        const micCtx = new AudioContext({ latencyHint: "interactive" });
        mic = { ctx: micCtx, stream };
        try {
            await micCtx.audioWorklet.addModule(worklet);
            const capture = new AudioWorkletNode(micCtx, "vdi-mic");
            capture.port.onmessage = (e) => {
                if (ws && ws.readyState === WebSocket.OPEN) ws.send(e.data);
            };
            micCtx.createMediaStreamSource(stream).connect(capture);
            // Its output is silent; connected so the browser keeps it running.
            capture.connect(micCtx.destination);
        } catch (e) {
            stopMic();
            throw e;
        }
    }

    function stopMic() {
        if (!mic) return;
        mic.stream.getTracks().forEach((t) => t.stop());
        mic.ctx.close();
        mic = null;
    }

    function updateButton(error) {
        button.classList.toggle("on", !!mic);
        button.title = error ? `Microphone unavailable: ${error}`
            : mic ? "Microphone on (click to mute)" : "Microphone off (click to unmute)";
    }

    function addMicButton() {
        const style = document.createElement("style");
        style.textContent = `
            #vdi-mic { position: fixed; right: 12px; bottom: 12px; z-index: 2147483647;
                width: 36px; height: 36px; padding: 7px; border: 0; border-radius: 50%;
                background: rgba(40, 40, 40, .6); color: #fff; cursor: pointer; opacity: .5; }
            #vdi-mic:hover { opacity: 1; }
            #vdi-mic.on { background: #c62828; opacity: .9; }
            #vdi-mic .slash { display: inline; }
            #vdi-mic.on .slash { display: none; }`;
        document.head.append(style);

        button = document.createElement("button");
        button.id = "vdi-mic";
        button.tabIndex = -1;
        button.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22" fill="none"
            stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <rect x="9" y="3" width="6" height="11" rx="3"/>
            <path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>
            <path class="slash" d="M4 4l16 16"/></svg>`;
        // Keep keyboard focus on the remote desktop.
        button.addEventListener("mousedown", (e) => e.preventDefault());
        button.addEventListener("click", async () => {
            if (mic) {
                stopMic();
                updateButton();
                return;
            }
            button.disabled = true; // until the permission prompt is answered
            try {
                await startMic();
                updateButton();
            } catch (e) {
                console.error("vdi-audio: microphone:", e);
                updateButton(e.message || e.name);
            } finally {
                button.disabled = false;
            }
        });
        document.body.append(button);
        updateButton();
    }

    async function init() {
        ctx = new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
        await ctx.audioWorklet.addModule(worklet);
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
