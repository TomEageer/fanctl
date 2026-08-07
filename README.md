# Fanctl — Smart Fan Control for Apple Silicon Macs

**[中文文档 / Chinese README](README.zh-CN.md)**

Open-source fan speed control for Apple Silicon MacBooks (M1 / M2 / M3 / M4 / M4 Pro / M4 Max). Keeps your Mac cool and quiet with a self-learning thermal controller — a free alternative to Macs Fan Control and TG Pro.

![Fanctl menu bar](docs/images/menubar.png)

macOS's default fan curve is tuned for silence: fans barely spin until the chip approaches 90 °C, so the chassis runs warm all day. Fanctl gives the thermal target back to you — by default it holds the CPU die around **50 °C** on AC power, with fans that ramp gently instead of howling.

## Features

- **Power feedforward** — whole-system power draw (≈ heat output) maps directly to a baseline RPM, so fans react to load *before* temperature rises
- **Self-learning thermal model** — the controller continuously learns your machine's power→RPM→cooling relationship at steady state and persists it; prediction gets better the longer it runs
- **Power-spike preemption** — a fast/slow power EMA crossover bumps fan speed the moment load jumps (e.g. a build starts), not seconds later
- **PI feedback with anti-windup** — converges on the exact equilibrium RPM, and glides back down as soon as temperature falls (no fans pinned at max after the load ends)
- **Gentle slew-rate limiting** — RPM changes are rate-limited (200/400/700 RPM per 3 s tick by urgency; always 150 down), so you never hear a sudden howl
- **Battery aware** — releases control and stops sampling on battery power; zero battery cost
- **Fail-safe by design** — any exit path (crash, kill, uninstall) restores macOS's own fan control first; targets are always clamped to hardware min/max
- **Menu bar app + control panel window** — temperature in the menu bar, a 2-series history chart (temperature + RPM, color-coded by control mode), a dual-dot speed control (solid dot = live RPM, ring = your manual setpoint), and a standalone window for people who hide their menu bar
- **Rendering-friendly** — 15 s refresh when closed, 2 s when open, text redraws only on change (plays nice with macOS Liquid Glass)

## Install

### Download (recommended)

1. Grab `Fanctl-x.y.z.zip` from [Releases](https://github.com/TomEageer/fanctl/releases), unzip
2. Drag `Fanctl.app` into **Applications**
3. First open: **right-click → Open** (ad-hoc signed; or `xattr -dr com.apple.quarantine /Applications/Fanctl.app`)
4. Click **Install** when prompted — one admin password installs the background service; done, it runs at boot

The app bundles everything (SMC tool, control daemon, a copy of [macmon](https://github.com/vladkens/macmon)). No Homebrew or Terminal required.

### Build from source

```bash
make
sudo ./install.sh
```

Uninstall with `sudo ./uninstall.sh` — fans are handed back to macOS before anything is removed.

## How it works

```
power telemetry ──feedforward──┐
                               ├─→ target RPM ──slew limit──→ SMC fan registers
temperature ──PI (anti-windup)─┘        ↑
        └── steady-state learning updates the feedforward gain (persisted)
```

- `smcfan` (C) talks to the AppleSMC fan registers (`F0Md` / `F0Tg`) — the same channel commercial fan utilities use
- `fanctld` (Python, root LaunchDaemon) runs the control loop every ~3 s
- `Fanctl.app` (Swift, AppKit) is the menu bar UI; it only reads status files the daemon writes — UI and SMC never contend

## FAQ

**How do I control fan speed on an Apple Silicon MacBook (M1/M2/M3/M4)?**
Install Fanctl. It exposes three modes: smart control (temperature-targeted), manual fixed speed (drag the dot), and max speed. Or hand control back to macOS at any time.

**Why is my MacBook hot but the fans stay quiet?**
Apple's firmware fan curve prioritizes silence and lets the chassis run warm — fans don't spin up hard until the die nears 90 °C. That's by design, and it's exactly what Fanctl changes.

**Can it keep my Mac below 50 °C?**
Under light load, yes. Under sustained heavy load (compiling, local LLMs), physics wins: air cooling settles around 55–65 °C even at max RPM. Fanctl holds the equilibrium honestly instead of screaming at max forever.

**Does it drain battery?**
No — on battery power Fanctl releases fan control and stops sampling entirely.

**Is it safe?**
Every exit path restores system fan control first; targets are clamped to the hardware's own min/max range; the chip's built-in thermal protection always outranks any software. Don't run two fan controllers at once (Fanctl + Macs Fan Control fighting over SMC can temporarily wedge the interface).

**Macs Fan Control / TG Pro alternative?**
Fanctl is free, open-source (MIT), has no subscription, no menu-bar meters burning CPU, and adds closed-loop temperature control with a learning feedforward — not just manual sliders and static curves.

## Requirements

- Apple Silicon Mac, macOS 13+ (developed and tested on M4 Pro)
- Building from source needs Xcode Command Line Tools

## Keywords

Mac fan control · Apple Silicon fan speed · M1 M2 M3 M4 fan control · macOS fan curve · MacBook overheating fix · SMC fan · menu bar temperature monitor · Macs Fan Control alternative · TG Pro alternative · smcFanControl Apple Silicon

## License

MIT — see [LICENSE](LICENSE). Bundles [macmon](https://github.com/vladkens/macmon) (MIT) for sensor reading.
