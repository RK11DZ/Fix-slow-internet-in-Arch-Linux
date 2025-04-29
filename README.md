# Internet Boost Script

This script (`boost-net.sh`) provides an advanced and automated way to optimize and accelerate your internet connection on Linux systems (especially useful for Wi-Fi connections). It applies multiple system-level tweaks to network configuration, including packet processing, queue sizing, congestion control, DNS optimization, and more.

## 🚀 Features

- Enables BBR congestion control
- Adjusts MTU for better packet performance
- Tweaks TCP parameters (window scaling, fast open, sack)
- Disables IPv6 to avoid latency issues
- Sets efficient DNS resolvers (Cloudflare, Google, Quad9)
- Enlarges RX/TX ring buffers and tx queue
- Enables advanced offloading options (TSO, GSO, GRO)
- Tunes network coalescing delay (rx/tx-usecs)
- Activates `irqbalance` for load balancing on multi-core CPUs
- Applies RPS (Receive Packet Steering) settings
- Sets aggressive memory limits for TCP buffers
- Applies `sysctl` changes persistently
- Supports speed testing
- Fully reversible with `--reverse` option

## 📦 Requirements

- Linux system (tested on Arch, Debian, Ubuntu)
- `ethtool`, `iwconfig`, `speedtest-cli`, `lshw`, `systemd`

Install requirements on Arch:
```bash
sudo pacman -S ethtool wireless_tools speedtest-cli lshw
```

## 🔧 Usage

### 1. Save and make the script executable
```bash
chmod +x boost-net.sh
```

### 2. Run the optimization (as root or with sudo)
```bash
./boost-net.sh
```

### 3. To revert changes and return to default settings:
```bash
./boost-net.sh --reverse
```

## 📁 Logs
All actions are logged into `internet_boost.log` for easy tracking.

## ⚠️ Disclaimer
Use this script at your own risk. It is optimized for performance but might not be ideal for all systems or networks. Always monitor your network behavior after applying changes.

---
Made with 💻 and 🧠 for power users.

