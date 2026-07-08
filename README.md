# Rathole RDP - Native Remote Desktop Tunnel

A lightweight, secure reverse tunnel that makes any Windows PC accessible via **standard RDP clients** (mstsc.exe, Microsoft Remote Desktop, etc.) from anywhere in the world.

No VPN. No extra client software on the connecting side. Full RDP with clipboard, audio, drives, and multi-monitor support.

## How It Works

```
┌──────────────────┐         ┌─────────────────┐         ┌──────────────────┐
│   Windows PC     │ ──────► │   Your VPS      │ ◄────── │  You (anywhere)  │
│   (rathole       │ outbound│   (rathole       │  RDP    │  (mstsc.exe)     │
│    client)       │  tunnel │    server)       │  :3389  │                  │
└──────────────────┘         └─────────────────┘         └──────────────────┘
```

1. The Windows PC runs a small background service that opens an **outbound** TCP tunnel to your VPS.
2. The VPS exposes port 3389 (or any port you choose) and forwards incoming RDP connections through the tunnel.
3. You connect with any standard RDP client to `your-vps-address:port` — full native RDP experience.

The tunnel automatically reconnects if the PC changes network (WiFi roaming, IP change, etc.).

## Features

- **Zero-config on connecting side** — just use mstsc.exe or any RDP client
- **Full RDP** — clipboard, audio, local drives, printers, multi-monitor
- **Auto-reconnect** — survives network changes, sleep/wake, reboots
- **Encrypted tunnel** — Noise Protocol (same crypto as WireGuard/Signal)
- **Minimal footprint** — rathole binary is ~3MB, uses <5MB RAM
- **Windows service** — starts on boot, runs as SYSTEM, auto-restarts on crash
- **Power management** — integrated presets to keep the PC awake for RDP
- **Multi-slot** — one VPS server supports unlimited PCs on different ports

## Requirements

### Server (VPS/Linux)
- Any Linux VPS with a public IP
- Root access
- Ports 2333 (control) + one RDP port per PC (e.g., 3389, 3390, ...)

### Client (Windows PC)
- Windows 10/11 Pro, Enterprise, or Education (Home does not support RDP hosting)
- Administrator access (for installation)
- Outbound TCP access to your VPS (port 2333)

## Quick Start

### 1. Server Setup (VPS)

```bash
# Download and run the deploy script
sudo bash server/deploy.sh
```

The script will:
- Download rathole for your architecture
- Generate a config with tokens (save them!)
- Set up systemd service with auto-restart
- Configure firewall and rate limiting

### 2. Client Setup (Windows PC)

1. Download this repository (or just the `client/` folder)
2. Edit `slots.txt` with your server details and tokens
3. Right-click `client/setup.bat` → **Run as administrator**
4. Select your slot → done!

Or use **Custom mode** [C] to enter server/port/token manually.

### 3. Connect

Open any RDP client and connect to:
- `your-vps-ip` (if using port 3389, no port needed)
- `your-vps-ip:3390` (if using a different port)

## File Structure

```
rathole-rdp/
├── client/
│   ├── setup.bat          # Run this (auto-elevates to admin)
│   └── script.ps1         # Main PowerShell installer
├── server/
│   └── deploy.sh          # Linux server setup script
├── slots.txt              # Slot configuration (tokens + ports)
├── slots.txt.example      # Example/template
└── README.md
```

## Slots File Format

```
# name|port|token|address|server
elinajobb|3389|your-secret-token-here|elinajobb.example.com|157.180.34.39
rdp1|3390|another-token-here|rdp1.example.com|157.180.34.39
```

| Field | Description |
|-------|-------------|
| name | Unique slot identifier |
| port | Remote port on VPS (3389 = no port needed in RDP client) |
| token | Shared secret between server and client (generate with `openssl rand -hex 32`) |
| address | DNS name or IP you'll use to connect (for display only) |
| server | VPS IP or hostname (where rathole server runs) |

## Security

The system uses multiple layers of protection:

| Layer | Protection |
|-------|-----------|
| Tunnel auth | Token-based — only authorized clients can establish tunnels |
| Tunnel encryption | Noise Protocol — all traffic encrypted end-to-end |
| Windows NLA | Network Level Authentication — credentials required before session |
| Rate limiting | iptables — max 5 new connections per minute per source IP |
| fail2ban | Auto-bans IPs after repeated failed connections |

### Recommendations
- Use strong Windows passwords (the last line of defense)
- Consider IP whitelisting on VPS if you connect from known locations
- Use non-standard ports (3390+) to reduce scan noise
- Enable Windows account lockout policy (5 failed attempts → lock)

## Power Management

The client script includes integrated power management to keep the PC available:

| Preset | What it does |
|--------|-------------|
| MAX | Never sleeps (AC+battery), lid does nothing, shutdown button hidden |
| High | Never sleeps, lid does nothing, shutdown button visible |
| Balanced (recommended) | Never sleeps on AC, normal on battery |
| Low+ | Only keeps network alive, doesn't change sleep |
| Low (reset) | Restores Windows defaults |

Access via `[P]` in the manage menu, or automatically offered after installation.

## FAQ

**Q: Can I use this without a domain name?**
Yes! Just connect to the VPS IP directly. DNS is optional convenience.

**Q: What if the PC goes to sleep?**
Use the built-in power management presets (Balanced or higher) to prevent sleep.

**Q: What if my home internet goes down?**
The tunnel will reconnect automatically when internet returns. The service retries every 5 seconds.

**Q: Is this safe to expose to the internet?**
With strong passwords + rate limiting + NLA, it's reasonably safe. For maximum security, add IP whitelisting on the VPS firewall.

**Q: Can multiple PCs share one VPS?**
Yes! Each PC gets its own port and token. One rathole server handles all of them.

## Credits

- [rathole](https://github.com/rapiz1/rathole) — The excellent Rust-based reverse proxy
- [WinSW](https://github.com/winsw/winsw) — Windows Service Wrapper

## License

MIT License — by JPaasovaara
