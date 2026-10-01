// Jitter buffer for the PCM chunks vdi-audio.js receives (interleaved stereo
// s16le, at the AudioContext's 48 kHz). Playback starts once TARGET frames are
// queued; if the queue grows past MAX (network burst, suspended context), the
// oldest audio is dropped to get back to TARGET so latency stays low.
const TARGET = 0.06 * sampleRate;
const MAX = 0.25 * sampleRate;

class VdiAudio extends AudioWorkletProcessor {
    constructor() {
        super();
        this.queue = [];   // Int16Array chunks
        this.offset = 0;   // next sample index in queue[0]
        this.frames = 0;   // frames queued, minus those already played
        this.playing = false;
        this.port.onmessage = (e) => this.push(new Int16Array(e.data));
    }

    push(chunk) {
        this.queue.push(chunk);
        this.frames += chunk.length / 2;
        if (this.frames > MAX) {
            while (this.frames > TARGET) {
                this.frames -= (this.queue.shift().length - this.offset) / 2;
                this.offset = 0;
            }
        }
    }

    process(inputs, outputs) {
        const [left, right] = outputs[0];
        if (!this.playing) {
            if (this.frames < TARGET) return true;
            this.playing = true;
        }
        for (let i = 0; i < left.length; i++) {
            if (this.queue.length === 0) {
                this.playing = false; // underrun: the rest stays silent
                break;
            }
            const chunk = this.queue[0];
            left[i] = chunk[this.offset] / 32768;
            right[i] = chunk[this.offset + 1] / 32768;
            this.offset += 2;
            this.frames--;
            if (this.offset >= chunk.length) {
                this.queue.shift();
                this.offset = 0;
            }
        }
        return true;
    }
}

registerProcessor("vdi-audio", VdiAudio);

// Microphone: resamples the first input channel from the context's rate to
// 48 kHz (linear interpolation) and posts 20 ms chunks of mono s16le.
const MIC_RATE = 48000;
const MIC_CHUNK = MIC_RATE / 50;

class VdiMic extends AudioWorkletProcessor {
    constructor() {
        super();
        this.step = sampleRate / MIC_RATE;
        this.pos = 0;      // read position in the current block; -1 = prev
        this.prev = 0;     // last sample of the previous block
        this.chunk = new Int16Array(MIC_CHUNK);
        this.n = 0;
    }

    process(inputs) {
        const input = inputs[0][0];
        if (!input) return true;
        while (this.pos < input.length - 1) {
            const i = Math.floor(this.pos);
            const a = i < 0 ? this.prev : input[i];
            const v = a + (input[i + 1] - a) * (this.pos - i);
            this.chunk[this.n++] = Math.max(-32768, Math.min(32767, Math.round(v * 32768)));
            if (this.n === MIC_CHUNK) {
                this.port.postMessage(this.chunk.buffer, [this.chunk.buffer]);
                this.chunk = new Int16Array(MIC_CHUNK);
                this.n = 0;
            }
            this.pos += this.step;
        }
        this.pos -= input.length;
        this.prev = input[input.length - 1];
        return true;
    }
}

registerProcessor("vdi-mic", VdiMic);
