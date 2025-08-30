import os, signal, subprocess, time, threading
from pathlib import Path
from typing import List, Optional

import yaml
from fastapi import FastAPI, Response, status, Body
from fastapi.responses import HTMLResponse, PlainTextResponse

APP_DIR = Path("/opt/app")
CONFIG_PATH = Path("/data/config.yml")
MEDIAMTX_BIN = "/opt/mediamtx/mediamtx"
MEDIAMTX_CFG = "/etc/mediamtx.yml"

# Глобальные процессы
procs_lock = threading.Lock()
proc_mediamtx: Optional[subprocess.Popen] = None
proc_ffmpeg: Optional[subprocess.Popen] = None
proc_rist: Optional[subprocess.Popen] = None

app = FastAPI(title="RIST Sender Manager", version="0.1")

def _ensure_default_config():
    if not CONFIG_PATH.exists():
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        default = {
            "source": {
                "mode": "test",
                "rtmp_url": "rtmp://127.0.0.1:1935/live/stream",
                "uvc_video": "/dev/video0",
                "uvc_audio": "hw:1,0",
            },
            "encode": {
                "video_bitrate": "6000k",
                "audio_bitrate": "128k",
                "framerate": 25,
                "gop_seconds": 2,
            },
            "rist": {
                "profile": 1,
                "buffer_ms": 1200,
                "aes": 128,
                "secret": "pass123",
                "base_udp_port": 10000,
                "peers": ["rist://127.0.0.1:8000?weight=5"],
            },
            "logging": {"to_file": True, "dir": "/var/log/rist", "verbose": 3, "stats_ms": 0},
        }
        CONFIG_PATH.write_text(yaml.safe_dump(default, sort_keys=False), encoding="utf-8")

def load_cfg() -> dict:
    _ensure_default_config()
    return yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8")) or {}

def log_files(cfg: dict):
    logdir = Path(cfg.get("logging", {}).get("dir", "/var/log/rist"))
    return (logdir / "mediamtx.log", logdir / "ffmpeg.log", logdir / "ristsender.log")

def start_mediamtx(cfg: dict):
    global proc_mediamtx
    if proc_mediamtx and proc_mediamtx.poll() is None:
        return
    logs_dir = Path(cfg.get("logging", {}).get("dir", "/var/log/rist"))
    if cfg.get("logging", {}).get("to_file", True):
        logs_dir.mkdir(parents=True, exist_ok=True)
        logf = open(logs_dir / "mediamtx.log", "ab", buffering=0)
        proc_mediamtx = subprocess.Popen([MEDIAMTX_BIN, MEDIAMTX_CFG], stdout=logf, stderr=subprocess.STDOUT)
    else:
        proc_mediamtx = subprocess.Popen([MEDIAMTX_BIN, MEDIAMTX_CFG])

def stop_proc(p: Optional[subprocess.Popen]):
    if p and p.poll() is None:
        try:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        except Exception:
            pass

def build_ffmpeg_cmd(cfg: dict) -> List[str]:
    src = cfg.get("source", {})
    enc = cfg.get("encode", {})
    rist = cfg.get("rist", {})
    base_udp = str(rist.get("base_udp_port", 10000))

    common = [
        "ffmpeg", "-nostdin", "-loglevel", "warning", "-hide_banner",
        "-fflags", "+genpts", "-mpegts_flags", "+resend_headers", "-muxpreload", "0", "-muxdelay", "0",
        "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
        "-b:v", enc.get("video_bitrate", "6000k"),
        "-maxrate", enc.get("video_bitrate", "6000k"),
        "-bufsize", enc.get("video_bitrate", "6000k"),
        "-g", str(int(enc.get("framerate", 25)) * int(enc.get("gop_seconds", 2))),
        "-keyint_min", str(int(enc.get("framerate", 25)) * int(enc.get("gop_seconds", 2))),
        "-sc_threshold", "0",
        "-c:a", "aac", "-b:a", enc.get("audio_bitrate", "128k"),
        "-ar", "48000", "-ac", "2",
        "-f", "mpegts", f"udp://127.0.0.1:{base_udp}?pkt_size=1316&fifo_size=1000000&overrun_nonfatal=1",
    ]

    mode = src.get("mode", "test")
    if mode == "rtmp":
        inp = ["-re", "-fflags", "nobuffer", "-flags", "low_delay", "-rtmp_live", "live", "-i", src.get("rtmp_url", "rtmp://127.0.0.1:1935/live/stream"), "-map", "0:v:0", "-map", "0:a?"]
    elif mode == "uvc":
        inp = ["-f", "v4l2", "-thread_queue_size", "1024", "-framerate", str(enc.get("framerate", 25)), "-i", src.get("uvc_video", "/dev/video0"),
               "-f", "alsa", "-thread_queue_size", "1024", "-i", src.get("uvc_audio", "hw:1,0"),
               "-map", "0:v:0", "-map", "1:a:0"]
    else:  # test
        inp = ["-re", "-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate={enc.get('framerate',25)},format=yuv420p",
               "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
               "-map", "0:v:0", "-map", "1:a:0"]
    return ["ffmpeg"] + inp + common[5:]  # аккуратно склеиваем

def clean_url(u: str) -> str:
    for k in ("profile", "buffer"):
        u = u.replace(f"?{k}=", "?").replace(f"&{k}=", "&")
    while "&&" in u:
        u = u.replace("&&","&")
    if u.endswith("&"):
        u = u[:-1]
    return u

def ensure_secret(u: str, cfg: dict) -> str:
    sec = cfg.get("rist", {}).get("secret", "")
    aes = cfg.get("rist", {}).get("aes", 0)
    if sec:
        if "secret=" not in u: u += f"&secret={sec}"
        if "aes-type=" not in u: u += f"&aes-type={aes}"
    return u

def build_ristsender_cmd(cfg: dict) -> Optional[List[str]]:
    rist = cfg.get("rist", {})
    peers = rist.get("peers", [])
    if not peers:
        return None
    peers = [ensure_secret(clean_url(p), cfg) for p in peers]
    joined = ",".join(peers)
    args = [
        "ristsender",
        "-i", f"udp://127.0.0.1:{rist.get('base_udp_port',10000)}",
        "-o", joined,
        "-p", str(rist.get("profile", 1)),
        "-b", str(rist.get("buffer_ms", 1200)),
        "-e", str(rist.get("aes", 0)),
        "-S", str(cfg.get("logging", {}).get("stats_ms", 1000)),
        "-v", str(cfg.get("logging", {}).get("verbose", 3)),
    ]
    if rist.get("secret"): args += ["-s", str(rist.get("secret"))]
    return args

def start_pipeline(cfg: dict):
    global proc_ffmpeg, proc_rist
    logs = cfg.get("logging", {})
    logdir = Path(logs.get("dir", "/var/log/rist"))
    to_file = logs.get("to_file", True)
    if to_file: logdir.mkdir(parents=True, exist_ok=True)

    # ristsender
    cmd_r = build_ristsender_cmd(cfg)
    if cmd_r:
        if to_file:
            rf = open(logdir / "ristsender.log", "ab", buffering=0)
            proc_rist = subprocess.Popen(cmd_r, stdout=rf, stderr=subprocess.STDOUT)
        else:
            proc_rist = subprocess.Popen(cmd_r)

    # ffmpeg
    cmd_f = build_ffmpeg_cmd(cfg)
    if to_file:
        ff = open(logdir / "ffmpeg.log", "ab", buffering=0)
        proc_ffmpeg = subprocess.Popen(cmd_f, stdout=ff, stderr=subprocess.STDOUT)
    else:
        proc_ffmpeg = subprocess.Popen(cmd_f)

def stop_pipeline():
    global proc_ffmpeg, proc_rist
    stop_proc(proc_ffmpeg); proc_ffmpeg = None
    stop_proc(proc_rist);    proc_rist = None

@app.on_event("startup")
def _startup():
    _ensure_default_config()
    cfg = load_cfg()
    Path(cfg.get("logging", {}).get("dir", "/var/log/rist")).mkdir(parents=True, exist_ok=True)
    with procs_lock:
        start_mediamtx(cfg)
        start_pipeline(cfg)

@app.get("/", response_class=HTMLResponse)
def index():
    return (APP_DIR / "static/index.html").read_text(encoding="utf-8")

@app.get("/api/config/raw", response_class=PlainTextResponse)
def get_config_raw():
    _ensure_default_config()
    return CONFIG_PATH.read_text(encoding="utf-8")

@app.post("/api/config/raw", response_class=Response)
def set_config_raw(body: str = Body(..., media_type="text/plain")):
    try:
        # валидация YAML
        yaml.safe_load(body)
    except Exception as e:
        return Response(f"YAML error: {e}", status_code=status.HTTP_400_BAD_REQUEST)
    CONFIG_PATH.write_text(body, encoding="utf-8")
    return Response("OK", status_code=200)

@app.post("/api/apply", response_class=PlainTextResponse)
def apply_config():
    cfg = load_cfg()
    with procs_lock:
        stop_pipeline()
        start_pipeline(cfg)
    return "reloaded"
