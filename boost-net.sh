#!/bin/bash
LOGFILE="internet_boost.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') =====" | tee -a "$LOGFILE"
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
[[ -z "$IFACE" ]] && echo "خطأ: لا يمكن تحديد واجهة الشبكة." && exit 1

driver_info(){ sudo lshw -C network 2>/dev/null | grep -A5 "$IFACE"; }
DRIVER=$(driver_info | grep "driver=" | head -n1 | cut -d'=' -f2)
echo "واجهة: $IFACE, التعريف: ${DRIVER:-غير معروف}" | tee -a "$LOGFILE"
action="apply"
[[ "$1" == "--reverse" ]] && action="revert"
echo "إجراء: $action" | tee -a "$LOGFILE"

install_pkg(){ dpkg -s "$1" &>/dev/null || sudo apt-get install -y "$1"; }

#!/bin/bash

apply_optimizations() {
  IFACE=$(ip route | awk '/default/ {print $5; exit}')
  DRIVER=$(basename "$(readlink -f /sys/class/net/$IFACE/device/driver)")
  LOGFILE="net-boost.log"

  sudo mkdir -p /etc/NetworkManager/conf.d
  sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<EOF
[connection]
wifi.powersave = 2
EOF
  sudo systemctl restart NetworkManager || echo "⚠️ تعذر إعادة تشغيل NetworkManager"

  sudo ip link set "$IFACE" mtu 1400 || echo "⚠️ فشل ضبط MTU"
  sudo ethtool -G "$IFACE" rx 4096 tx 4096 || echo "⚠️ فشل ضبط حلقات RX/TX"
  sudo ethtool -K "$IFACE" tso on gso on gro on || echo "⚠️ فشل ضبط offloading"
  sudo ip link set dev "$IFACE" txqueuelen 2000 || echo "⚠️ فشل ضبط txqueuelen"
  echo ffff | sudo tee /sys/class/net/$IFACE/queues/rx-0/rps_cpus >/dev/null || echo "⚠️ فشل ضبط rps_cpus"
  sudo ethtool -C "$IFACE" rx-usecs 10 tx-usecs 10 || echo "⚠️ فشل ضبط coalesce"
  sudo modprobe -r "$DRIVER" 2>/dev/null || true
  sudo modprobe "$DRIVER" power_save=0 2>/dev/null || true

  if ! systemctl list-unit-files | grep -q irqbalance; then
    sudo apt install -y irqbalance
  fi
  sudo systemctl enable irqbalance.service
  sudo systemctl start irqbalance.service || echo "⚠️ فشل تشغيل irqbalance"

  sudo tee /etc/sysctl.d/99-net-optimize.conf >/dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.core.netdev_max_backlog=5000
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.tcp_ecn=1
net.core.busy_poll=50
net.core.busy_read=50
net.core.rps_sock_flow_entries=32768
EOF
  sudo sysctl --system || echo "⚠️ فشل تطبيق sysctl"

  sudo mkdir -p /etc/systemd/resolved.conf.d
  sudo tee /etc/systemd/resolved.conf.d/dns.conf >/dev/null <<EOF
[Resolve]
DNS=1.1.1.1 9.9.9.9 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
DNSSEC=yes
Cache=yes
EOF
  sudo systemctl enable systemd-resolved.service
  sudo systemctl restart systemd-resolved.service || echo "⚠️ فشل إعادة تشغيل systemd-resolved"
  sudo systemd-resolve --flush-caches 2>/dev/null || true

  if ! command -v speedtest-cli &>/dev/null; then
    sudo apt install -y speedtest-cli
  fi

  speedtest-cli || echo "⚠️ فشل اختبار السرعة"
  echo "✅ تم تطبيق تسريع الإنترنت بنجاح." | tee -a "$LOGFILE"
}

revert_optimizations(){
  sudo ip link set "$IFACE" mtu 1500
  sudo ethtool -G "$IFACE" rx 256 tx 256
  sudo ethtool -K "$IFACE" tso off gso off gro off
  sudo ip link set dev "$IFACE" txqueuelen 1000
  echo 0 | sudo tee /sys/class/net/$IFACE/queues/rx-0/rps_cpus >/dev/null || true
  sudo ethtool -C "$IFACE" rx-usecs 0 tx-usecs 0
  sudo rm -f /etc/sysctl.d/99-net-optimize.conf
  sudo sysctl --system
  sudo rm -rf /etc/systemd/resolved.conf.d/dns.conf
  sudo systemctl restart systemd-resolved.service
  sudo systemd-resolve --flush-caches 2>/dev/null || true
  echo "تم استعادة الإعدادات الافتراضية" | tee -a "$LOGFILE"
}

[[ "$action" == "apply" ]] && apply_optimizations || revert_optimizations
