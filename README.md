# llama-reaper

GPU cleanup tools for shared servers running llama.cpp. Automatically detects and kills idle `llama-server` / `llama-cli` processes that are blocking the GPU.

Solves the "someone forgot to stop their llama-server and now nobody else can use the GPU" problem. Ollama handles this with automatic model unloading — llama.cpp doesn't, so we built this.

## What's included

| Tool | Purpose |
|------|---------|
| `llama-reaper` | Watchdog that scores idle llama.cpp processes and kills them on a schedule |
| `llama-status` | GPU dashboard showing everything running on the GPU (llama.cpp + Ollama) |
| `llama-serve` | Optional wrapper for `llama-server` with auto-shutdown after inactivity |

Ollama processes are **never** targeted. Only `llama-server`, `llama-cli`, and `llama-cpp` processes are eligible for reaping.

## Quick start

```bash
git clone https://github.com/cgam-ai-sig/llama-reaper.git
cd llama-reaper
sudo ./install.sh --with-reaper
```

This installs all three tools to `/usr/local/bin/` and sets up the system-wide reaper (checks every 15 min, kills processes idle for 30+ min).

If you just want the tools without the automated reaper:

```bash
sudo ./install.sh
```

## How the reaper works

Each run, the reaper scores every llama.cpp process on several idle signals:

| Signal | Points | What it means |
|--------|--------|---------------|
| No GPU memory allocated | +3 | Process isn't on the GPU at all |
| GPU memory held, 0% utilization | +3 | Sitting on VRAM but not computing |
| No CPU time change since last check | +3 | Process hasn't done any work |
| No network connections (for servers) | +2 | Nobody is connected to this server |
| Running > 2 hours | +1 | Age bonus |
| Running > 8 hours | +2 | Larger age bonus (replaces the +1) |

**Score >= 6** → WARN: a marker file is written, the process is logged as idle.

**Score >= 8** → KILL candidate. But not immediately — the reaper uses a two-phase approach:

1. **First run at score >= 8**: writes a warning marker with a timestamp. Process keeps running.
2. **Next run (5+ minutes later)**: if the marker is still there and the score is still >= 8, the process is killed (SIGTERM, then SIGKILL after 10s if needed).

If the score drops below 6 between runs (e.g., someone connects), the warning marker is cleared. The process gets a second chance.

### The `--max-idle` age gate

`--max-idle` (default: 30 minutes) is **not** an idle duration — it's an **age gate**. Processes younger than `--max-idle` minutes are completely ignored, regardless of their idle score. This prevents the reaper from killing a server that was just started and hasn't received its first request yet.

### Timeline example

With the default `--interval 15 --max-idle 30`:

1. **t=0**: User starts `llama-server`, walks away.
2. **t=15**: Reaper runs. Process is 15 minutes old — younger than `--max-idle` (30m). **Skipped.**
3. **t=30**: Reaper runs. Process is 30 minutes old — now eligible. Scores high. **WARN marker written.**
4. **t=45**: Reaper runs. Marker is 15 minutes old (> 5 min grace). Score still high. **KILLED.**

Worst case: an idle process survives ~45 minutes.

With a tighter `--interval 5 --max-idle 30`:

1. **t=30**: First eligible check. **WARN.**
2. **t=35**: Grace period passed. **KILLED.**

Worst case: ~35 minutes.

## Configuration

### Install the reaper cron

```bash
# System-wide (all users, needs root)
llama-reaper install --system --interval 15 --max-idle 30

# User-only (just your processes)
llama-reaper install --interval 5 --max-idle 20
```

**System mode** creates `/etc/cron.d/llama-reaper` and runs as root, managing all users' processes.

**User mode** adds an entry to your personal crontab, only managing your own processes.

### Remove the reaper cron

```bash
llama-reaper uninstall           # user cron
llama-reaper uninstall --system  # system cron
```

### One-off checks

```bash
llama-reaper --dry-run --verbose  # see what would happen, don't kill anything
llama-reaper list                 # show all llama.cpp processes with scores
llama-reaper --force              # skip grace period, kill immediately if score >= 8
```

## llama-status

GPU dashboard with four output modes:

```bash
llama-status              # full color dashboard
llama-status --compact    # single-line summary
llama-status --json       # machine-readable JSON
llama-status --no-color   # no ANSI codes (for piping/logging)
```

Example output (`--no-color`):

```
━━━ GPU ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  GPU      NVIDIA GeForce RTX 4090
  VRAM     14227 / 24564 MiB  ━━━━━━━━━───── 57%
  Temp     52°C    Power   138W / 450W    Util  12%

━━━ Ollama ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Status   ● running (1 models loaded)
  Active   llama3.1:8b (5 GB, until 4m)

━━━ llama.cpp ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PID      USER     VRAM        MODEL                          PORT    UPTIME
  185334   alice    8413 MiB    Qwen2.5-Coder-32B-Q4_K_M.gguf 8080    2h 14m
  191207   bob      5120 MiB    mistral-7b-v0.3.Q5_K_M.gguf   9090    45m

━━━ Reaper ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Status   ● active (every 15m, max-idle 30m)
```

Shows GPU stats, Ollama status with loaded models and TTL, all llama.cpp processes with user/PID/VRAM/model/port/uptime, and whether the reaper is installed.

## llama-serve (optional)

Wraps `llama-server` with per-session auto-shutdown. The server stops itself after a configurable period of inactivity (no active requests, no connections).

```bash
llama-serve --timeout 30 -- -m model.gguf -c 4096 -ngl 99
llama-serve --timeout 15 --port 9090 -- -m model.gguf --port 9090
```

Not needed if you're running the reaper — but useful if you want immediate, per-session control without waiting for the reaper's schedule.

## Uninstall

```bash
sudo ./install.sh uninstall          # remove tools from /usr/local/bin/
sudo ./install.sh uninstall --purge  # also remove /var/lib/llama-reaper/ state files
```

## Requirements

- Linux (tested on Ubuntu 24.04)
- bash 4+
- nvidia-smi (NVIDIA GPU drivers)
- coreutils, procps, iproute2 (`ss`), curl
- No root needed for day-to-day use (only for install and system-wide reaper setup)

## License

MIT
