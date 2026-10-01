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
