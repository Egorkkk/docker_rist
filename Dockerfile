# =========================
# 1) СБОРКА librist (builder)
# =========================
FROM debian:bookworm-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential meson ninja-build python3 pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# librist (даёт ristsender/ristreceiver)
RUN git clone --depth=1 https://code.videolan.org/rist/librist.git /tmp/librist \
 && meson setup /tmp/librist/build /tmp/librist --buildtype=release \
 && meson compile -C /tmp/librist/build \
 && meson install  -C /tmp/librist/build \
 && (command -v ristsender   || cp /tmp/librist/build/tools/ristsender   /usr/local/bin/) \
 && (command -v ristreceiver || cp /tmp/librist/build/tools/ristreceiver /usr/local/bin/) \
 && ldconfig

# =========================
# 2) ИСТОЧНИК MediaMTX
# =========================
FROM bluenviron/mediamtx:latest AS mediamtx_src
# бинарь: /mediamtx

# =========================
# 3) ФИНАЛЬНЫЙ ОБРАЗ (runtime)
# =========================
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl ffmpeg bash coreutils tini \
    iproute2 iptables iputils-ping libssl3 python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# librist CLI
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/bin/ristsender   /usr/local/bin/ristsender
COPY --from=builder /usr/local/bin/ristreceiver /usr/local/bin/ristreceiver
RUN ldconfig

# MediaMTX + его конфиг
COPY --from=mediamtx_src /mediamtx /opt/mediamtx/mediamtx
COPY mediamtx.yml /etc/mediamtx.yml

# ... всё то же выше ...

# Мини-панель (менеджер процессов + HTML)
COPY app /opt/app

# >>> вместо pip3 в системный python — создаём venv и ставим пакеты туда
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
 && python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir fastapi "uvicorn[standard]" pyyaml

# Веб-сервер менеджера (он же поднимает процессы)
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini","--","/opt/venv/bin/uvicorn","manager:app","--app-dir","/opt/app","--host","0.0.0.0","--port","8080"]

