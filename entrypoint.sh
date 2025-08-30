#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s %s\n' "[entrypoint]" "$*"; }

# ========= Логи =========
LOG_DIR="${LOG_DIR:-/var/log/rist}"
LOG_TO_FILE="${LOG_TO_FILE:-0}"
RIST_STATS_MS="${RIST_STATS_MS:-1000}"   # ristsender --statsinterval (мс); 0 = выкл

if [[ "$LOG_TO_FILE" = "1" ]]; then
  mkdir -p "$LOG_DIR"
fi

# ========= ENV / defaults =========
SRC="${SRC:-rtmp}"                      # rtmp | uvc | test
RTMP_IN_URL="${RTMP_IN_URL:-rtmp://127.0.0.1:1935/live/stream}"
UVC_VIDEO="${UVC_VIDEO:-/dev/video0}"
UVC_AUDIO="${UVC_AUDIO:-hw:1,0}"

VIDEO_BITRATE="${VIDEO_BITRATE:-6000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
PRESET="${PRESET:-veryfast}"
TUNE="${TUNE:-zerolatency}"
FRAMERATE="${FRAMERATE:-25}"
GOP_SECONDS="${GOP_SECONDS:-2}"

# RIST
RIST_PROFILE="${RIST_PROFILE:-1}"       # 0 simple, 1 main, 2 advanced
RIST_AES="${RIST_AES:-128}"             # 0|128|256
RIST_SECRET="${RIST_SECRET:-}"          # PSK; пусто => без шифрования
RIST_BUFFER_MS="${RIST_BUFFER_MS:-1200}"
RIST_URLS="${RIST_URLS:-}"              # ;-separated list of peers
BASE_UDP_PORT="${BASE_UDP_PORT:-10000}" # один локальный UDP-порт для ristsender
VERBOSE="${VERBOSE:-3}"                 # ristsender verbosity (0..6)

# ========= graceful shutdown =========
pids=()
cleanup() {
  log "stopping..."
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -n "${MEDIAMTX_PID:-}" ]]; then
    kill "$MEDIAMTX_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ========= MediaMTX (RTMP ingest) =========
log "starting MediaMTX"
if [[ "$LOG_TO_FILE" = "1" ]]; then
  /opt/mediamtx/mediamtx /etc/mediamtx.yml >"$LOG_DIR/mediamtx.log" 2>&1 &
else
  /opt/mediamtx/mediamtx /etc/mediamtx.yml &
fi
MEDIAMTX_PID=$!
pids+=("$MEDIAMTX_PID")

if [[ "$SRC" == "rtmp" ]]; then
  log "waiting RTMP listener on :1935 ..."
  for i in {1..30}; do
    if (command -v ss >/dev/null 2>&1 && ss -lnt '( sport = :1935 )' | grep -q ':1935') \
       || (command -v netstat >/dev/null 2>&1 && netstat -lnt | grep -q ':1935'); then
      log "RTMP is listening"
      break
    fi
    sleep 0.3
    [[ $i -eq 30 ]] && log "WARN: RTMP might not be listening yet, continuing anyway"
  done
fi

# ========= ffmpeg input + map =========
ff_in=()
ff_map=()
case "$SRC" in
  rtmp)
    ff_in=(-re -fflags nobuffer -flags low_delay -rtmp_live live -i "$RTMP_IN_URL")
    ff_map=(-map 0:v:0 -map 0:a?)   # audio опционально
    ;;
  uvc)
    ff_in=(-f v4l2 -thread_queue_size 1024 -framerate "$FRAMERATE" -i "$UVC_VIDEO"
           -f alsa  -thread_queue_size 1024 -i "$UVC_AUDIO")
    ff_map=(-map 0:v:0 -map 1:a:0)
    ;;
  test)
    ff_in=(-re -f lavfi -i "testsrc2=size=1280x720:rate=$FRAMERATE,format=yuv420p"
           -f lavfi -i "sine=frequency=1000:sample_rate=48000")
    ff_map=(-map 0:v:0 -map 1:a:0)
    ;;
  *)
    log "ERROR: unknown SRC=$SRC"; exit 1;;
esac

# ========= подготовим список RIST peers (в одной сессии) =========
IFS=';' read -r -a RIST_ARR <<< "$RIST_URLS"
if [[ -z "$RIST_URLS" || ${#RIST_ARR[@]} -eq 0 ]]; then
  log "WARN: RIST_URLS is empty — stream will be encoded but not sent."
fi

# чистим неподдерживаемые ключи и подставляем секрет/шифр при необходимости
for i in "${!RIST_ARR[@]}"; do
  url="${RIST_ARR[$i]}"

  # убрать profile/buffer из URL — ristsender задаст через флаги
  url="${url//\?profile=/\?}"
  url="${url//&profile=/&}"
  url="${url//\?buffer=/\?}"
  url="${url//&buffer=/&}"
  url="${url//&&/&}"
  url="${url%\&}"

  if [[ -n "$RIST_SECRET" ]]; then
    [[ "$url" != *"secret="*   ]] && url="${url}&secret=${RIST_SECRET}"
    [[ "$url" != *"aes-type="* ]] && url="${url}&aes-type=${RIST_AES}"
  fi

  RIST_ARR[$i]="$url"
done

# для ristsender несколько пиров задаются через запятую
RIST_PEERS_JOINED=$(IFS=','; echo "${RIST_ARR[*]:-}")

# ========= стартуем ristsender (ОДИН процесс, мультипир) =========
if [[ -n "$RIST_PEERS_JOINED" ]]; then
  log "[ristsender] udp://127.0.0.1:${BASE_UDP_PORT} -> $RIST_PEERS_JOINED"
  if [[ "$LOG_TO_FILE" = "1" ]]; then
    ristsender \
      -i "udp://127.0.0.1:${BASE_UDP_PORT}" \
      -o "$RIST_PEERS_JOINED" \
      -p "$RIST_PROFILE" \
      -b "$RIST_BUFFER_MS" \
      ${RIST_SECRET:+-s "$RIST_SECRET"} \
      -e "$RIST_AES" \
      -S "$RIST_STATS_MS" \
      -v "$VERBOSE" >"$LOG_DIR/ristsender.log" 2>&1 &
  else
    ristsender \
      -i "udp://127.0.0.1:${BASE_UDP_PORT}" \
      -o "$RIST_PEERS_JOINED" \
      -p "$RIST_PROFILE" \
      -b "$RIST_BUFFER_MS" \
      ${RIST_SECRET:+-s "$RIST_SECRET"} \
      -e "$RIST_AES" \
      -S "$RIST_STATS_MS" \
      -v "$VERBOSE" &
  fi
  pids+=($!)
fi

# ========= ffmpeg: один encode -> локальный UDP для ristsender =========
log "starting ffmpeg pipeline (SRC=$SRC, V=$VIDEO_BITRATE, A=$AUDIO_BITRATE)"
common_ffmpeg_out=(
  -c:v libx264 -preset "$PRESET" -tune "$TUNE"
  -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize "$VIDEO_BITRATE"
  -g $((FRAMERATE*GOP_SECONDS)) -keyint_min $((FRAMERATE*GOP_SECONDS)) -sc_threshold 0
  -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 -ac 2
  -fflags +genpts
  -mpegts_flags +resend_headers
  -muxpreload 0 -muxdelay 0
)

if [[ -n "$RIST_PEERS_JOINED" ]]; then
  if [[ "$LOG_TO_FILE" = "1" ]]; then
    ffmpeg -nostdin -loglevel warning -hide_banner \
      "${ff_in[@]}" "${ff_map[@]}" \
      "${common_ffmpeg_out[@]}" \
      -f mpegts "udp://127.0.0.1:${BASE_UDP_PORT}?pkt_size=1316&fifo_size=1000000&overrun_nonfatal=1" \
      >"$LOG_DIR/ffmpeg.log" 2>&1 &
  else
    ffmpeg -nostdin -loglevel warning -hide_banner \
      "${ff_in[@]}" "${ff_map[@]}" \
      "${common_ffmpeg_out[@]}" \
      -f mpegts "udp://127.0.0.1:${BASE_UDP_PORT}?pkt_size=1316&fifo_size=1000000&overrun_nonfatal=1" &
  fi
else
  # нет RIST-пиров — гоняем в /dev/null для отладки ingest
  if [[ "$LOG_TO_FILE" = "1" ]]; then
    ffmpeg -nostdin -loglevel warning -hide_banner \
      "${ff_in[@]}" "${ff_map[@]}" \
      "${common_ffmpeg_out[@]}" \
      -f mpegts /dev/null >"$LOG_DIR/ffmpeg.log" 2>&1 &
  else
    ffmpeg -nostdin -loglevel warning -hide_banner \
      "${ff_in[@]}" "${ff_map[@]}" \
      "${common_ffmpeg_out[@]}" \
      -f mpegts /dev/null &
  fi
fi
FF_PID=$!; pids+=("$FF_PID")

# ========= wait =========
wait "$FF_PID"
