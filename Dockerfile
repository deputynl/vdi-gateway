# vdi-gateway: KasmVNC web client + FreeRDP 3 pinned to one RDP host.
#
# Base is Ubuntu 24.04 (noble): KasmVNC 1.5.0 ships no Ubuntu 26.04 build, and
# noble-updates carries a current FreeRDP 3.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

ARG KASMVNC_VERSION=1.5.0
ARG KASMVNC_SHA256_AMD64=f599fe02e2175b9817b6165f74a5d2bebdc73118dde9181ba3410963bed7ae1e
ARG KASMVNC_SHA256_ARM64=c9199cf4753208bfb69fd016a9780242bebfc43370cc38c97d61e90a3c783e04
# noble-updates/noble-security only keep the newest build; bump this when a
# FreeRDP security update supersedes it (apt-cache policy freerdp3-x11).
ARG FREERDP_VERSION=3.32.0+dfsg-0ubuntu0.24.04.1
ARG MATCHBOX_VERSION=1.2.2+git20200512-1build1

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) sha="$KASMVNC_SHA256_AMD64" ;; \
        arm64) sha="$KASMVNC_SHA256_ARM64" ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fsSL -o /tmp/kasmvnc.deb \
        "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_noble_${KASMVNC_VERSION}_${arch}.deb"; \
    echo "${sha}  /tmp/kasmvnc.deb" | sha256sum -c -; \
    apt-get install -y --no-install-recommends \
        /tmp/kasmvnc.deb \
        "freerdp3-x11=${FREERDP_VERSION}" \
        "matchbox-window-manager=${MATCHBOX_VERSION}" \
        x11-utils \
        pulseaudio pulseaudio-utils python3-websockets; \
    apt-get purge -y --auto-remove curl ca-certificates; \
    rm -rf /var/lib/apt/lists/* /tmp/kasmvnc.deb; \
    if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi; \
    useradd --create-home --uid 1000 --shell /usr/sbin/nologin app; \
    install -d -m 1777 /tmp/.X11-unix; \
    install -d -o app -g app /home/app/.config /home/app/.config/freerdp

COPY --chmod=755 entrypoint.sh audio/vdi-audio-server /usr/local/bin/

# Audio player for the web client, loaded by both of its entry pages. The
# ?v=<content hash> makes browsers and CDNs fetch new versions after an update;
# vdi-audio.js passes the same query on to the worklet.
COPY audio/vdi-audio.js audio/vdi-audio-worklet.js /usr/share/kasmvnc/www/
RUN set -eux; \
    cd /usr/share/kasmvnc/www; \
    v="$(cat vdi-audio.js vdi-audio-worklet.js | sha256sum | cut -c1-12)"; \
    for page in index.html vnc.html; do \
        sed -i "s|</head>|<script src=\"./vdi-audio.js?v=$v\" defer></script></head>|" "$page"; \
        grep -q "vdi-audio.js?v=$v" "$page"; \
    done

USER app
WORKDIR /home/app
ENV HOME=/home/app LANG=C.UTF-8
EXPOSE 8080 8081
VOLUME /home/app/.config/freerdp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
