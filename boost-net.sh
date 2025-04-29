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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # Reset color

apply_optimizations() {
  LOGFILE="/var/log/net_optimize.log"
  IFACE=$(ip route | awk '/default/ {print $5; exit}')
  DRIVER=$(basename "$(readlink -f /sys/class/net/$IFACE/device/driver)")

  if [ -z "$IFACE" ]; then
    echo -e "${RED}⚠️ لم يتم العثور على واجهة الشبكة الافتراضية${NC}" >> "$LOGFILE"
    return 1
  fi

  echo -e "${BLUE}بدأ تطبيق التحسينات للشبكة في: $(date)${NC}" >> "$LOGFILE"

  if ! command -v sudo >/dev/null; then
    echo -e "${RED}⚠️ sudo غير مثبت${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! command -v ip >/dev/null; then
    echo -e "${RED}⚠️ ip غير مثبت${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! command -v ethtool >/dev/null; then
    echo -e "${RED}⚠️ ethtool غير مثبت${NC}" >> "$LOGFILE"
    return 1
  fi

  sudo mkdir -p /etc/NetworkManager/conf.d
  if ! sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<EOF
[connection]
wifi.powersave = 2
EOF
  then
    echo -e "${RED}⚠️ فشل في إنشاء ملف التكوين لـ NetworkManager${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo systemctl restart NetworkManager; then
    echo -e "${RED}⚠️ فشل إعادة تشغيل NetworkManager${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo ip link set "$IFACE" mtu 1400; then
    echo -e "${RED}⚠️ فشل ضبط MTU${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo ethtool -G "$IFACE" rx 8192 tx 8192; then
    echo -e "${RED}⚠️ فشل ضبط حلقات RX/TX${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo ethtool -K "$IFACE" tso on gso on gro on; then
    echo -e "${RED}⚠️ فشل ضبط offloading${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo ip link set dev "$IFACE" txqueuelen 2000; then
    echo -e "${RED}⚠️ فشل ضبط txqueuelen${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! echo ffff | sudo tee /sys/class/net/$IFACE/queues/rx-0/rps_cpus >/dev/null; then
    echo -e "${RED}⚠️ فشل ضبط rps_cpus${NC}" >> "$LOGFILE"
    return 1
  fi

  if sudo ethtool -c "$IFACE" | grep -q 'Coalesce parameters'; then
    if ! sudo ethtool -C "$IFACE" rx-usecs 5 tx-usecs 5; then
      echo -e "${RED}⚠️ فشل ضبط coalesce${NC}" >> "$LOGFILE"
      return 1
    fi
  else
    echo -e "${YELLOW}⚠️ coalesce غير مدعوم على الواجهة $IFACE${NC}" >> "$LOGFILE"
  fi

  if ! sudo modprobe -r "$DRIVER" 2>/dev/null; then
    echo -e "${RED}⚠️ فشل إزالة driver${NC}" >> "$LOGFILE"
  fi

  if ! sudo modprobe "$DRIVER" power_save=0 2>/dev/null; then
    echo -e "${RED}⚠️ فشل إعادة تحميل driver${NC}" >> "$LOGFILE"
    return 1
  fi

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
  if ! sudo sysctl --system; then
    echo -e "${RED}⚠️ فشل تطبيق sysctl${NC}" >> "$LOGFILE"
    return 1
  fi

  sudo mkdir -p /etc/systemd/resolved.conf.d
  if ! sudo tee /etc/systemd/resolved.conf.d/dns.conf >/dev/null <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
DNSSEC=no
Cache=yes
EOF
  then
    echo -e "${RED}⚠️ فشل في ضبط DNS${NC}" >> "$LOGFILE"
    return 1
  fi

  if ! sudo systemctl restart systemd-resolved; then
    echo -e "${RED}⚠️ فشل إعادة تشغيل systemd-resolved${NC}" >> "$LOGFILE"
    return 1
  fi

  sudo systemd-resolve --flush-caches 2>/dev/null || true

  if ! command -v speedtest-cli >/dev/null; then
    if ! sudo apt install -y speedtest-cli; then
      echo -e "${RED}⚠️ فشل تثبيت speedtest-cli${NC}" >> "$LOGFILE"
      return 1
    fi
  fi

  if ! speedtest-cli --secure; then
    echo -e "${RED}⚠️ فشل اختبار السرعة${NC}" >> "$LOGFILE"
    return 1
  fi

  echo -e "${GREEN}✅ تم تطبيق التسريع بنجاح${NC}" >> "$LOGFILE"
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
