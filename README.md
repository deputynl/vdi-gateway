# vdi-gateway

[![Release](https://img.shields.io/github/v/release/deputynl/vdi-gateway)](https://github.com/deputynl/vdi-gateway/releases)
[![Image](https://img.shields.io/badge/ghcr.io-deputynl%2Fvdi--gateway-blue)](https://github.com/deputynl/vdi-gateway/pkgs/container/vdi-gateway)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

One container that shows a FreeRDP 3 session to **one fixed RDP host** in the browser, via KasmVNC.

```
browser ──HTTP/WS──▶ Xvnc (KasmVNC 1.5.0 + web client, :1)
   ▲                    └── matchbox-window-manager
   │                          └── xfreerdp3 3.32 /f +dynamic-resolution ──RDP──▶ TARGET_HOST
   │                                    │ /sound
   └──WS /vdi-audio── vdi-audio-server ◀── PulseAudio null sink
```

Built for GNOME Remote Desktop in **Remote Login** mode on Ubuntu 26.04. FreeRDP logs in with the system RDP credentials, the GDM greeter appears, and after you log in FreeRDP follows GNOME's ServerRedirection into your session.

## Quick start

```sh
curl -fsSLO https://raw.githubusercontent.com/deputynl/vdi-gateway/main/docker-compose.yml
curl -fsSL -o .env https://raw.githubusercontent.com/deputynl/vdi-gateway/main/.env.example
chmod 600 .env   # then edit .env
docker compose up -d
docker compose logs -f
```

The web client listens on `127.0.0.1:8080`; put a reverse proxy in front of it (see [3. Reverse proxy](#3-reverse-proxy)). Put local changes (networks, ports, proxy labels) in a `docker-compose.override.yml` next to it; compose merges it automatically.

## Image

`ghcr.io/deputynl/vdi-gateway` for `linux/amd64` and `linux/arm64`.

| Tag | Meaning |
|---|---|
| `latest` | Most recent release |
| `YYYYMMDDHHMMSS` | A specific release (UTC build time), see [Releases](https://github.com/deputynl/vdi-gateway/releases) |

To build it yourself instead: clone the repo and run `docker build -t vdi-gateway .`, or add `build: .` to the service in your override file and use `docker compose up -d --build`.

## Configuration

| Var | Default | Purpose |
|---|---|---|
| `TARGET_HOST` | required | RDP host (IPv6 literals in brackets) |
| `TARGET_PORT` | `3389` | RDP port |
| `RDP_USERNAME` / `RDP_PASSWORD` | required | GNOME Remote Desktop *system* credentials (`grdctl --system`) |
| `RDP_DOMAIN` | – | |
| `RDP_CERT_MODE` | `ignore` | `ignore`, or `tofu` (stored in the `freerdp-config` volume) |
| `KEYBOARD_LAYOUT` | – | FreeRDP `/kbd:layout:` value, e.g. `0x00000407` or `German` (`xfreerdp3 /list:kbd`) |
| `FREERDP_EXTRA_ARGS` | – | Extra FreeRDP args, split on whitespace (no quoting) |
| `KASM_USER` / `KASM_PASSWORD` | `kasm` / unset | KasmVNC basic auth. Unset password = auth **disabled** |
| `LISTEN_PORT` | `8080` | HTTP/WebSocket port |
| `AUDIO` | `on` | `on` or `off`: remote audio in the browser (see [Audio](#audio)) |
| `AUDIO_PORT` | `8081` | Audio WebSocket port |

Secrets never appear on a command line. FreeRDP gets all its arguments through `/args-from:stdin`, `kasmvncpasswd` reads the password from stdin, and both variables are removed from the environment before any child process starts.

When the RDP session ends (logout, network drop, server restart), a **Reconnect** dialog shows the reason. The container never reconnects by itself, because every connection creates a new GDM greeter session on the VM. If Xvnc or the window manager dies, the container exits non-zero and Docker restarts it.

## 1. VM prerequisites (Ubuntu 26.04)

- Enable Remote Login: *Settings → System → Remote Desktop → Remote Login*. Or from the CLI:
  ```sh
  sudo grdctl --system rdp set-tls-key  /etc/gnome-remote-desktop/rdp-tls.key
  sudo grdctl --system rdp set-tls-cert /etc/gnome-remote-desktop/rdp-tls.crt
  sudo grdctl --system rdp set-credentials <sys-user> <sys-pass>
  sudo grdctl --system rdp enable
  sudo systemctl enable --now gnome-remote-desktop.service
  ```
  The Settings panel generates the cert for you. From the CLI, create one first (e.g. `openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj /CN=$(hostname) -keyout rdp-tls.key -out rdp-tls.crt`, readable by the `gnome-remote-desktop` user).
- Firewall: allow 3389/tcp **only** from the Docker host.
- **Don't stay logged in locally as the same user** (e.g. in the Proxmox console). The handover after GDM fails if that user already has a local session.

## 2. Pre-flight test (any Linux machine)

```sh
xfreerdp3 /v:<vm> /u:<sys-user> /p:<sys-pass> /dynamic-resolution /cert:ignore
```
Log in at GDM and confirm you land in your session without a disconnect. If this fails, the container will fail the same way.

## 3. Reverse proxy

The proxy needs: WebSocket upgrade, HTTP/1.1 to the upstream, no buffering, and read/send timeouts of at least 1800 s. Use a dedicated hostname; subpaths are not supported.

**KasmVNC basic auth behind an IDP.** Let the proxy inject the KasmVNC credentials after the IDP check, so users never see a second login prompt:
`printf 'kasm:%s' "$KASM_PASSWORD" | base64 -w0` → `Authorization: Basic <that>`.
Or leave `KASM_PASSWORD` unset. Then the container logs a warning and anyone who reaches port 8080 controls the desktop, which is why compose binds it to 127.0.0.1.

KasmVNC counts every request without valid credentials as a failed login. It blacklists the client IP after 5 (from 10 s, growing), and it reads that IP from the **first** `X-Forwarded-For` entry. So the proxy must overwrite that header rather than append to it.

nginx:
```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 443 ssl;
    server_name rdp.example.com;
    # ssl_certificate ...; your IDP auth (auth_request / oauth2-proxy) ...

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Authorization "Basic a2FzbTpzZWNyZXQ=";   # kasm:secret
        proxy_buffering off;
        proxy_read_timeout 1800s;
        proxy_send_timeout 1800s;
    }

    # Remote audio (AUDIO=on): same settings, other port.
    location = /vdi-audio {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header Authorization "Basic a2FzbTpzZWNyZXQ=";   # kasm:secret
        proxy_buffering off;
        proxy_read_timeout 1800s;
        proxy_send_timeout 1800s;
    }
}
```

Traefik v3 (labels on the `vdi-gateway` service; drop the `ports:` mapping and share a network with Traefik). Traefik proxies WebSockets without extra config and doesn't trust incoming `X-Forwarded-For` by default.
```yaml
    labels:
      - traefik.enable=true
      - traefik.http.routers.rdp.rule=Host(`rdp.example.com`)
      - traefik.http.routers.rdp.service=rdp
      - traefik.http.routers.rdp.entrypoints=websecure
      - traefik.http.routers.rdp.tls=true
      - traefik.http.routers.rdp.middlewares=my-idp@file,rdp-basic
      - traefik.http.middlewares.rdp-basic.headers.customrequestheaders.Authorization=Basic a2FzbTpzZWNyZXQ=
      - traefik.http.services.rdp.loadbalancer.server.port=8080
      # Remote audio (AUDIO=on). The longer rule gives it priority over the router above.
      - traefik.http.routers.rdp-audio.rule=Host(`rdp.example.com`) && Path(`/vdi-audio`)
      - traefik.http.routers.rdp-audio.entrypoints=websecure
      - traefik.http.routers.rdp-audio.tls=true
      - traefik.http.routers.rdp-audio.middlewares=my-idp@file,rdp-basic
      - traefik.http.routers.rdp-audio.service=rdp-audio
      - traefik.http.services.rdp-audio.loadbalancer.server.port=8081
```
Traefik v3 has a 60 s entrypoint `readTimeout` by default. If sessions drop, raise it in the static config: `--entrypoints.websecure.transport.respondingTimeouts.readTimeout=1800s`.

## 4. The two-stage login is expected

1. System RDP credentials: automatic, from the env vars.
2. The GDM login screen in the browser: you log in as your normal user, and GNOME hands the connection over to your session.

## Audio

KasmVNC has no audio channel, so the gateway adds one. FreeRDP requests the remote desktop's audio (`/sound:sys:pulse`) and plays it into a PulseAudio null sink in the container. `vdi-audio-server` streams that sink over a WebSocket on `AUDIO_PORT`, and a small player injected into the KasmVNC page (`audio/vdi-audio.js`) plays it.

- The proxy must route **`/vdi-audio`** on the same hostname to port 8081 (examples above). Without that route the desktop works as before, just silently.
- The page must be served over HTTPS (or from `localhost`): browsers only allow the AudioWorklet player in secure contexts.
- Sound starts after your first click or key press in the page, because browsers block audio until then.
- The stream is uncompressed 48 kHz stereo PCM, about 1.5 Mbit/s while something plays. Silence is not sent.
- The player buffers 60 ms before it starts and drops audio when it falls more than 250 ms behind, so delay stays low.
- If `KASM_PASSWORD` is set, the audio server requires the same `Authorization` header as KasmVNC. It also rejects WebSocket handshakes whose `Origin` is a different host.
- On the VM, GNOME Remote Desktop sends audio once the client asks for it. If you hear nothing, check the `[audio]` and `[freerdp]` log lines, then test sound with a native client (`xfreerdp3 /sound ...`).
- Only playback is supported, no microphone.
- `AUDIO=off` turns all of it off.

## Notes / deviations from the spec

- **Base image is Ubuntu 24.04, not 26.04.** KasmVNC 1.5.0 has no 26.04 build. noble-updates ships a current FreeRDP 3 (3.32.0 at the time of writing). Ubuntu only keeps the latest build in -updates, so bump `FREERDP_VERSION` in the Dockerfile when a security update replaces it.
- **No `kasmvnc.yaml`.** `Xvnc` never reads it; only the interactive `kasmvncserver` wrapper does. All settings are Xvnc flags in `entrypoint.sh`, as in linuxserver's baseimage.
- **WebRTC/UDP**: KasmVNC 1.5.0 has no server switch to turn it off. Xvnc always binds UDP on the same port number. The web client leaves WebRTC off by default, `-publicIP 127.0.0.1` stops STUN lookups, and only TCP is published, so the WebSocket is the only usable transport.
- **Keyboard**: `-RawKeyboard 1` forwards the physical key (the browser's `event.code`) instead of a US-mapped keysym, so GNOME's own layout applies, as with a native RDP client. `KEYBOARD_LAYOUT` only sets the layout id announced to the server.
- **`RDP_CERT_MODE=tofu`**: on the first connection FreeRDP (seen with 3.31) prints a scary "host key has changed" banner even though nothing was stored yet. It then accepts and stores the cert. Later connections are silent.
- The image includes Mesa/LLVM (~180 MB) because the KasmVNC package hard-depends on `libgl1`/`libgbm1`, although nothing uses the GPU.

## License

[MIT](LICENSE)
