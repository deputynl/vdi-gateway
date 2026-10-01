#!/usr/bin/env bash
# Supervises Xvnc (KasmVNC) -> matchbox-window-manager -> xfreerdp3.
# FreeRDP is never restarted automatically: every connection creates a GDM
# greeter session on the target, so a restart waits for a click on "Reconnect".
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Docker HEALTHCHECK: expect a 200 from the web client. It must authenticate:
# KasmVNC counts requests without credentials as failed logins and blacklists
# the source IP after five of them.
if [[ ${1:-} == healthcheck ]]; then
    auth=
    if [[ -n ${KASM_PASSWORD:-} ]]; then
        auth="Authorization: Basic $(printf '%s:%s' "${KASM_USER:-kasm}" "$KASM_PASSWORD" | base64 -w0)"$'\r\n'
    fi
    exec 3<>"/dev/tcp/127.0.0.1/${LISTEN_PORT:-8080}"
    printf 'GET / HTTP/1.0\r\n%s\r\n' "$auth" >&3
    read -r status <&3
    [[ $status == "HTTP/1."?" 200 "* ]] && exit 0
    echo "unhealthy: ${status%$'\r'}"
    exit 1
fi

# ---------------------------------------------------------------- config ---
missing=()
for var in TARGET_HOST RDP_USERNAME RDP_PASSWORD; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
done
((${#missing[@]} == 0)) || die "missing required environment variable(s): ${missing[*]}"

TARGET_PORT=${TARGET_PORT:-3389}
LISTEN_PORT=${LISTEN_PORT:-8080}
RDP_CERT_MODE=${RDP_CERT_MODE:-ignore}
KASM_USER=${KASM_USER:-kasm}
AUDIO=${AUDIO:-on}
AUDIO_PORT=${AUDIO_PORT:-8081}
[[ $TARGET_PORT =~ ^[0-9]+$ ]] || die "TARGET_PORT must be a number"
[[ $LISTEN_PORT =~ ^[0-9]+$ ]] || die "LISTEN_PORT must be a number"
[[ $AUDIO_PORT =~ ^[0-9]+$ ]] || die "AUDIO_PORT must be a number"
[[ $AUDIO == on || $AUDIO == off ]] || die "AUDIO must be 'on' or 'off', got '$AUDIO'"
[[ $RDP_CERT_MODE == ignore || $RDP_CERT_MODE == tofu ]] ||
    die "RDP_CERT_MODE must be 'ignore' or 'tofu', got '$RDP_CERT_MODE'"

# Keep secrets in shell variables only, so no child process inherits them.
rdp_password=$RDP_PASSWORD
kasm_password=${KASM_PASSWORD:-}
unset RDP_PASSWORD KASM_PASSWORD

export DISPLAY=:1
run_dir=$(mktemp -d)

# start NAME CMD...: run CMD in the background with its output prefixed by
# [NAME]; the PID of CMD itself is left in $pid.
start() {
    local name=$1
    shift
    "$@" > >(sed -u "s/^/[$name] /") 2>&1 &
    pid=$!
}

trap 'log "received signal, shutting down"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

# ------------------------------------------------------------------ Xvnc ---
# Xvnc does not read kasmvnc.yaml (only the interactive kasmvncserver wrapper
# does), so all settings are passed as flags, as linuxserver.io does.
xvnc_args=(
    "$DISPLAY"
    -geometry 1280x800 -depth 24
    -interface 0.0.0.0 -websocketPort "$LISTEN_PORT"
    -httpd /usr/share/kasmvnc/www
    -sslOnly 0                      # plain HTTP/WS; TLS ends at the reverse proxy
    -SecurityTypes None             # access control is HTTP basic auth (or the proxy)
    -AcceptSetDesktopSize 1         # browser size drives the X display size
    -AcceptCutText 1 -SendCutText 1 # clipboard in both directions
    -RawKeyboard 1                  # pass physical keys through; GNOME's layout applies
    -publicIP 127.0.0.1             # no STUN lookups; the UDP/WebRTC port is never published
    -AlwaysShared
    -nolisten tcp
    -http-header Cross-Origin-Embedder-Policy=require-corp
    -http-header Cross-Origin-Opener-Policy=same-origin
    -Log '*:stdout:30'
)

if [[ -n $kasm_password ]]; then
    passwd_file=$HOME/.kasmpasswd
    rm -f "$passwd_file"
    printf '%s\n%s\n' "$kasm_password" "$kasm_password" |
        kasmvncpasswd -u "$KASM_USER" -w "$passwd_file" >/dev/null
    xvnc_args+=(-KasmPasswordFile "$passwd_file")
    log "KasmVNC basic auth enabled for user '$KASM_USER'"
else
    xvnc_args+=(-disableBasicAuth)
    log "WARNING: KASM_PASSWORD is not set, KasmVNC basic auth is DISABLED."
    log "WARNING: anyone who can reach port $LISTEN_PORT controls the remote desktop;"
    log "WARNING: expose this container only through an authenticating reverse proxy."
fi
# The audio server accepts exactly the header the web client sends to Xvnc.
audio_auth=
[[ -z $kasm_password ]] ||
    audio_auth="Basic $(printf '%s:%s' "$KASM_USER" "$kasm_password" | base64 -w0)"
unset kasm_password

start xvnc Xvnc "${xvnc_args[@]}"
xvnc_pid=$pid
# PID -> name of the processes whose exit ends the container.
declare -A critical=([$pid]=Xvnc)
for _ in $(seq 50); do
    xdpyinfo >/dev/null 2>&1 && break
    kill -0 "$xvnc_pid" 2>/dev/null || die "Xvnc exited during startup"
    sleep 0.2
done
xdpyinfo >/dev/null 2>&1 || die "X display $DISPLAY did not come up"
log "Xvnc ready on $DISPLAY, web client on http://0.0.0.0:$LISTEN_PORT/"

# -------------------------------------------------------- window manager ---
# matchbox gives every top-level window the full screen and resizes it when
# the root window changes size (RandR), which is what the resize chain needs.
# The xmessage reconnect prompt is shown as a centred dialog instead.
start wm matchbox-window-manager -use_titlebar no -use_cursor yes -force_dialogs xmessage
critical[$pid]="window manager"

# ----------------------------------------------------------------- audio ---
# FreeRDP plays into a PulseAudio null sink; vdi-audio-server streams its
# monitor to the browser over WebSocket on AUDIO_PORT.
if [[ $AUDIO == on ]]; then
    export PULSE_SERVER=unix:$run_dir/pulse.sock
    # Keep Pulse's runtime, state and cookie files in the private run dir.
    export PULSE_RUNTIME_PATH=$run_dir/pulse PULSE_STATE_PATH=$run_dir/pulse
    export PULSE_COOKIE=$run_dir/pulse/cookie
    start pulse pulseaudio --daemonize=no --system=no -n \
        --exit-idle-time=-1 --realtime=no --high-priority=no --log-target=stderr \
        -L "module-native-protocol-unix socket=$run_dir/pulse.sock auth-anonymous=1" \
        -L "module-null-sink sink_name=rdp rate=48000 channels=2 sink_properties=device.description=RDP"
    critical[$pid]=PulseAudio
    for _ in $(seq 50); do
        pactl info >/dev/null 2>&1 && break
        kill -0 "$pid" 2>/dev/null || die "PulseAudio exited during startup"
        sleep 0.2
    done
    pactl info >/dev/null 2>&1 || die "PulseAudio did not come up"

    export AUDIO_PORT
    start audio vdi-audio-server < <(printf '%s\n' "$audio_auth")
    critical[$pid]="audio server"
    log "audio enabled, WebSocket on port $AUDIO_PORT (route /vdi-audio to it)"
else
    log "audio disabled"
fi
unset audio_auth

# --------------------------------------------------------------- FreeRDP ---
log "$(xfreerdp3 /version 2>&1 | head -n1)"

freerdp_args=(
    "/v:$TARGET_HOST" "/port:$TARGET_PORT"
    "/u:$RDP_USERNAME" "/p:$rdp_password"
    "/cert:$RDP_CERT_MODE"
    /f -toggle-fullscreen
    +dynamic-resolution
    /gfx
    /clipboard:direction-to:all,files-to:off
)
[[ -z ${RDP_DOMAIN:-} ]] || freerdp_args+=("/d:$RDP_DOMAIN")
[[ -z ${KEYBOARD_LAYOUT:-} ]] || freerdp_args+=("/kbd:layout:$KEYBOARD_LAYOUT")
[[ $AUDIO == off ]] || freerdp_args+=(/sound:sys:pulse,dev:rdp)
read -r -a extra_args <<<"${FREERDP_EXTRA_ARGS:-}"
freerdp_args+=("${extra_args[@]}")
unset rdp_password

# Arguments (including the password) go through stdin, one per line, so they
# never show up in argv / ps.
start_freerdp() {
    log "connecting to $TARGET_HOST:$TARGET_PORT as '$RDP_USERNAME' (cert: $RDP_CERT_MODE)"
    xfreerdp3 /args-from:stdin \
        < <(printf '%s\n' "${freerdp_args[@]}") \
        > >(tee "$run_dir/freerdp.log" | sed -u 's/^/[freerdp] /') 2>&1 &
    freerdp_pid=$!
}

# Exit codes from client/X11/xfreerdp.h (enum XF_EXIT_CODE).
describe_exit() {
    case $1 in
        0) echo "Disconnected." ;;
        1) echo "Disconnected by the server." ;;
        2) echo "Logged off." ;;
        3) echo "Idle timeout." ;;
        4) echo "Logon timeout." ;;
        5) echo "Session taken over by another connection." ;;
        7) echo "Connection denied by the server." ;;
        11) echo "Disconnected by user." ;;
        12) echo "Logged off." ;;
        131 | 141 | 147) echo "Could not connect to $TARGET_HOST:$TARGET_PORT." ;;
        132 | 134 | 154) echo "Authentication failed (check RDP_USERNAME / RDP_PASSWORD)." ;;
        139 | 140) echo "Could not resolve $TARGET_HOST." ;;
        143) echo "TLS handshake failed (with RDP_CERT_MODE=tofu: did the server certificate change?)." ;;
        155) echo "Access denied." ;;
        *) echo "FreeRDP exited with code $1." ;;
    esac
}

# wait_for PID...: wait until a critical process or one of the given PIDs
# exits. Exits the container if a critical process died; otherwise sets $rc.
wait_for() {
    local exited
    rc=0
    wait -n -p exited "${!critical[@]}" "$@" || rc=$?
    [[ -z ${critical[$exited]:-} ]] || die "${critical[$exited]} exited (code $rc)"
}

while true; do
    start_freerdp
    wait_for "$freerdp_pid"
    reason=$(describe_exit "$rc")
    detail=$(grep -E '\[(ERROR|FATAL)\]' "$run_dir/freerdp.log" | tail -n1 | sed -E 's/^.*\]: *//' || true)
    log "FreeRDP exited with code $rc: $reason"

    # xmessage exits 0 via the Reconnect button; if the window is closed any
    # other way, show it again.
    rc=1
    until ((rc == 0)); do
        LC_ALL=C xmessage -center -buttons Reconnect:0 -default Reconnect -file - \
            < <(printf 'Remote desktop session ended.\n\n%s\n%s\n' "$reason" "${detail:+($detail)}") \
            > >(sed -u 's/^/[dialog] /') 2>&1 &
        wait_for $!
        ((rc == 0)) || sleep 1
    done
    log "reconnect requested"
done
