#!/bin/bash

LOGFILE="arch_boost_auto_ar.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') - سكريبت تسريع الشبكة التلقائي لـ Arch Linux (بالعربية) ====="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

install_pkg_arch() {
  local pkg_name=$1
  local is_critical=${2:-false}

  if ! pacman -Q "$pkg_name" &>/dev/null; then
    echo -e "${BLUE}معلومة:${NC} الحزمة '$pkg_name' غير مثبتة. جاري محاولة التثبيت..."
    if sudo pacman -Syu --noconfirm "$pkg_name"; then
      echo -e "${GREEN}نجاح:${NC} تم تثبيت الحزمة '$pkg_name'."
      return 0
    else
      echo -e "${RED}خطأ:${NC} فشل تثبيت الحزمة '$pkg_name'. يرجى التأكد من اتصالك بالإنترنت وصحة المستودعات."
      if [[ "$is_critical" == "true" ]]; then
        echo -e "${RED}خطأ فادح:${NC} هذه الحزمة ضرورية لعمل السكربت. سيتم الإنهاء."
        exit 1
      else
         echo -e "${YELLOW}تحذير:${NC} هذه الحزمة اختيارية أو يمكن الاستغناء عنها مؤقتًا. سيتم المتابعة..."
         return 1
      fi
    fi
  fi
  return 0
}

get_hardware_specs() {
    echo -e "${BLUE}معلومة:${NC} جار فحص مواصفات الجهاز الأساسية..."
    CPU_CORES=$(nproc 2>/dev/null)
    if [[ -z "$CPU_CORES" || ! "$CPU_CORES" =~ ^[0-9]+$ || "$CPU_CORES" -eq 0 ]]; then
        echo -e "${YELLOW}تحذير:${NC} لم يتم تحديد عدد أنوية المعالج. بعض التحسينات قد لا تكون دقيقة."
        CPU_CORES=1 # افتراض نواة واحدة في حالة الفشل
    else
        echo -e "${GREEN}نجاح:${NC} عدد أنوية المعالج المكتشف: ${YELLOW}$CPU_CORES${NC}"
    fi
}

get_network_info() {
  echo -e "${BLUE}معلومة:${NC} جار البحث عن واجهة الشبكة الافتراضية..."
  IFACE=$(ip -o -4 route show to default | awk '{print $5}')
  if [[ -z "$IFACE" ]]; then
    echo -e "${RED}خطأ فادح:${NC} لم يتم العثور على واجهة شبكة افتراضية نشطة. تأكد من اتصالك بالشبكة."
    exit 1
  fi
  echo -e "${GREEN}نجاح:${NC} الواجهة المكتشفة: ${YELLOW}$IFACE${NC}"

  echo -e "${BLUE}معلومة:${NC} جار البحث عن تعريف (driver) الواجهة..."
  DRIVER_PATH=$(readlink -f /sys/class/net/$IFACE/device/driver)
  if [[ -n "$DRIVER_PATH" ]]; then
      DRIVER=$(basename "$DRIVER_PATH")
  else
      install_pkg_arch "pciutils" false
      DRIVER=$(lspci -k -s $(ethtool -i $IFACE | grep bus-info | awk '{print $2}') 2>/dev/null | grep 'Kernel driver in use:' | awk '{print $NF}')
  fi

  if [[ -n "$DRIVER" ]]; then
    echo -e "${GREEN}نجاح:${NC} التعريف المكتشف: ${YELLOW}$DRIVER${NC}"
  else
    echo -e "${YELLOW}تحذير:${NC} لم يتم اكتشاف التعريف تلقائيًا. بعض التحسينات الخاصة بالتعريف قد لا تُطبق."
    DRIVER=""
 fi
}

apply_optimizations() {
  echo -e "${BLUE}--- بدأ تطبيق تحسينات الشبكة ---${NC}"

  echo -e "${BLUE}معلومة (1/12):${NC} التحقق من/تعطيل وضع توفير الطاقة للواي فاي (NetworkManager)..."
  sudo mkdir -p /etc/NetworkManager/conf.d
  if ! sudo tee /etc/NetworkManager/conf.d/99-wifi-powersave-off-auto-ar.conf >/dev/null <<EOF
[connection]
wifi.powersave = 2
EOF
  then
    echo -e "${YELLOW}تحذير:${NC} فشل إنشاء ملف تعطيل توفير الطاقة لـ NetworkManager."
  else
    echo -e "${BLUE}معلومة:${NC} إعادة تشغيل NetworkManager لتطبيق التغيير..."
    if ! sudo systemctl restart NetworkManager; then
      echo -e "${YELLOW}تحذير:${NC} فشل إعادة تشغيل NetworkManager. قد تحتاج لإعادة تشغيله يدويًا أو إعادة تشغيل الجهاز."
    else
       echo -e "${GREEN}نجاح:${NC} تم تعطيل توفير الطاقة للواي فاي (إذا كان مدعومًا) وأعيد تشغيل NetworkManager."
    fi
  fi

  echo -e "${BLUE}معلومة (2/12):${NC} ضبط وحدة النقل القصوى (MTU)..."
  if ! sudo ip link set "$IFACE" mtu 1400; then
     current_mtu=$(ip link show "$IFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
     if [[ "$current_mtu" == "1400" ]]; then
        echo -e "${GREEN}نجاح:${NC} MTU مضبوط بالفعل على 1400."
     else
        echo -e "${YELLOW}تحذير:${NC} فشل ضبط MTU إلى 1400. القيمة الحالية: $current_mtu."
     fi
  else
    echo -e "${GREEN}نجاح:${NC} تم ضبط MTU إلى 1400."
  fi

  echo -e "${BLUE}معلومة (3/12):${NC} ضبط حجم حلقات الاستقبال/الإرسال (RX/TX) بشكل تكيفي..."
  local max_rx max_tx current_rx current_tx
  if ethtool_output=$(ethtool -g "$IFACE" 2>/dev/null); then
      max_rx=$(echo "$ethtool_output" | grep -i 'RX:' -A 2 | grep 'Pre-set maximums:' | awk '{print $NF}')
      max_tx=$(echo "$ethtool_output" | grep -i 'TX:' -A 2 | grep 'Pre-set maximums:' | awk '{print $NF}')
      current_rx=$(echo "$ethtool_output" | grep -i 'RX:' -A 1 | grep 'Current hardware settings:' | awk '{print $NF}')
      current_tx=$(echo "$ethtool_output" | grep -i 'TX:' -A 1 | grep 'Current hardware settings:' | awk '{print $NF}')

      if [[ -n "$max_rx" && -n "$max_tx" && "$max_rx" -gt 0 && "$max_tx" -gt 0 ]]; then
        echo -e "${BLUE}معلومة:${NC} الحد الأقصى RX: $max_rx, TX: $max_tx. القيم الحالية RX: $current_rx, TX: $current_tx."
        if [[ "$current_rx" == "$max_rx" && "$current_tx" == "$max_tx" ]]; then
            echo -e "${GREEN}نجاح:${NC} حلقات RX/TX مضبوطة بالفعل على الحد الأقصى."
        else
            echo -e "${BLUE}معلومة:${NC} جاري محاولة ضبط RX/TX إلى الحد الأقصى..."
            if ! sudo ethtool -G "$IFACE" rx "$max_rx" tx "$max_tx"; then
              exit_code=$?
              if [[ $exit_code -eq 75 ]]; then
                 echo -e "${YELLOW}تحذير:${NC} فشل ضبط حلقات RX/TX. القيمة المطلوبة ($max_rx/$max_tx) تتجاوز الحد الأقصى للجهاز. تم الإبقاء على القيم الحالية."
              elif [[ $exit_code -eq 22 ]]; then
                 echo -e "${YELLOW}تحذير:${NC} فشل ضبط حلقات RX/TX. وسيط غير صالح. قد لا تدعم الواجهة هذه القيم. تم الإبقاء على القيم الحالية."
              else
                 echo -e "${YELLOW}تحذير:${NC} فشل ضبط حلقات RX/TX إلى الحد الأقصى (رمز الخطأ: $exit_code). تم الإبقاء على القيم الحالية."
              fi
            else
              echo -e "${GREEN}نجاح:${NC} تم ضبط حلقات RX/TX إلى $max_rx/$max_tx."
            fi
        fi
      else
        echo -e "${YELLOW}تحذير:${NC} لم يتم تحديد القيم القصوى لحلقات RX/TX. تم تخطي الضبط التكيفي."
      fi
  else
      echo -e "${YELLOW}تحذير:${NC} فشل الحصول على معلومات حلقات RX/TX باستخدام 'ethtool -g'. تم تخطي الضبط."
  fi

  echo -e "${BLUE}معلومة (4/12):${NC} تفعيل ميزات تفريغ المعالجة (Offloading)..."
  if ! sudo ethtool -K "$IFACE" tso on gso on gro on; then
    echo -e "${YELLOW}تحذير:${NC} فشل تفعيل بعض ميزات Offloading (TSO, GSO, GRO). قد لا تكون مدعومة بالكامل."
  else
    echo -e "${GREEN}نجاح:${NC} تم تفعيل TSO, GSO, GRO (إذا كانت مدعومة)."
  fi

  echo -e "${BLUE}معلومة (5/12):${NC} ضبط طول قائمة انتظار الإرسال (Transmit Queue Length)..."
  if ! sudo ip link set dev "$IFACE" txqueuelen 2000; then
    echo -e "${YELLOW}تحذير:${NC} فشل ضبط txqueuelen إلى 2000."
  else
    echo -e "${GREEN}نجاح:${NC} تم ضبط txqueuelen إلى 2000."
  fi

  echo -e "${BLUE}معلومة (6/12):${NC} تفعيل توجيه حزم الاستقبال (RPS) بناءً على عدد الأنوية (${CPU_CORES})..."
  rps_path="/sys/class/net/$IFACE/queues/rx-0/rps_cpus"
  if [ -f "$rps_path" ]; then
      # حساب قناع الأنوية (CPU mask)
      # الحد الأقصى العملي لعدد الأنوية الذي يمكن تمثيله بسهولة هنا (e.g., 64)
      local cores_to_use=$(( CPU_CORES < 64 ? CPU_CORES : 64 ))
      local rps_mask_dec=$(( (1 << cores_to_use) - 1 ))
      local rps_mask_hex=$(printf '%x' "$rps_mask_dec")

      if [[ -n "$rps_mask_hex" && "$rps_mask_hex" != "0" ]]; then
         echo -e "${BLUE}معلومة:${NC} سيتم استخدام قناع الأنوية ${YELLOW}$rps_mask_hex${NC} لـ RPS."
         if ! echo "$rps_mask_hex" | sudo tee "$rps_path" >/dev/null; then
           echo -e "${YELLOW}تحذير:${NC} فشل ضبط rps_cpus بالقناع المحسوب ($rps_mask_hex)."
         else
           echo -e "${GREEN}نجاح:${NC} تم تفعيل RPS بالقناع المناسب."
         fi
      else
         echo -e "${YELLOW}تحذير:${NC} فشل حساب قناع الأنوية لـ RPS."
      fi
  else
      echo -e "${BLUE}معلومة:${NC} مسار rps_cpus غير متاح للواجهة $IFACE. تم تخطي تفعيل RPS."
  fi

  echo -e "${BLUE}معلومة (7/12):${NC} ضبط تجميع المقاطعات (Interrupt Coalescing)..."
  if sudo ethtool -c "$IFACE" 2>/dev/null | grep -qi 'Coalesce'; then
    echo -e "${BLUE}معلومة:${NC} الواجهة تدعم Coalescing. جاري محاولة ضبط القيم..."
    if ! sudo ethtool -C "$IFACE" rx-usecs 5 tx-usecs 5; then
      exit_code=$?
       if [[ $exit_code -eq 22 ]]; then
          echo -e "${YELLOW}تحذير:${NC} فشل ضبط قيم Coalesce (rx-usecs 5 tx-usecs 5). القيم قد تكون غير صالحة. تم تخطي الضبط."
       elif [[ $exit_code -eq 95 ]]; then
          echo -e "${YELLOW}تحذير:${NC} فشل ضبط قيم Coalesce. العملية غير مدعومة. تم تخطي الضبط."
       else
          echo -e "${YELLOW}تحذير:${NC} فشل ضبط قيم Coalesce (رمز الخطأ: $exit_code). تم تخطي الضبط."
       fi
    else
       echo -e "${GREEN}نجاح:${NC} تم ضبط قيم Coalesce."
    fi
  else
    echo -e "${BLUE}معلومة:${NC} الواجهة $IFACE لا تدعم تعديل قيم Coalesce. تم تخطي الضبط."
  fi

  if [[ -n "$DRIVER" ]]; then
      echo -e "${BLUE}معلومة (8/12):${NC} محاولة تعطيل توفير الطاقة لتعريف الشبكة ($DRIVER)..."
      if ! sudo modprobe -r "$DRIVER" && sudo modprobe "$DRIVER" power_save=0; then
          sudo modprobe -r "$DRIVER" 2>/dev/null
          if ! sudo modprobe "$DRIVER" power_save=0 2>/dev/null; then
              echo -e "${YELLOW}تحذير:${NC} لم يتمكن من إعادة تحميل التعريف $DRIVER مع power_save=0. الخيار قد لا يكون مدعومًا. جاري محاولة إعادة تحميل التعريف بدون الخيار..."
              if ! sudo modprobe "$DRIVER" 2>/dev/null; then
                 echo -e "${RED}خطأ:${NC} فشل إعادة تحميل التعريف $DRIVER حتى بدون خيارات."
              fi
          else
              echo -e "${GREEN}نجاح:${NC} تم إعادة تحميل التعريف $DRIVER مع تعطيل توفير الطاقة (إذا كان مدعومًا)."
          fi
      else
           echo -e "${GREEN}نجاح:${NC} تم إعادة تحميل التعريف $DRIVER مع تعطيل توفير الطاقة (إذا كان مدعومًا)."
      fi
  else
      echo -e "${BLUE}معلومة:${NC} لم يتم اكتشاف التعريف. تم تخطي خطوة إعادة تحميل التعريف."
  fi

  echo -e "${BLUE}معلومة (9/12):${NC} تطبيق إعدادات sysctl لتحسين أداء الشبكة..."
  sudo mkdir -p /etc/sysctl.d
  if ! sudo tee /etc/sysctl.d/99-net-optimize-auto-ar.conf >/dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.core.netdev_max_backlog=5000
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_ecn=1
net.core.rps_sock_flow_entries=32768
EOF
  then
      echo -e "${RED}خطأ:${NC} فشل في كتابة ملف إعدادات sysctl (/etc/sysctl.d/99-net-optimize-auto-ar.conf)."
  else
      echo -e "${BLUE}معلومة:${NC} جاري تطبيق إعدادات sysctl..."
      if ! sudo sysctl --system; then
        echo -e "${RED}خطأ:${NC} فشل تطبيق إعدادات sysctl. تحقق من صحة الملف والأذونات."
      else
        echo -e "${GREEN}نجاح:${NC} تم تطبيق إعدادات sysctl."
      fi
  fi

  echo -e "${BLUE}معلومة (10/12):${NC} ضبط خوادم DNS باستخدام systemd-resolved..."
  sudo mkdir -p /etc/systemd/resolved.conf.d
  if ! sudo tee /etc/systemd/resolved.conf.d/99-dns-auto-ar.conf >/dev/null <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8#Cloudflare Google
FallbackDNS=1.0.0.1 8.8.4.4#Cloudflare Google
DNSSEC=no
Cache=yes
EOF
  then
    echo -e "${RED}خطأ:${NC} فشل في إنشاء ملف إعدادات DNS (/etc/systemd/resolved.conf.d/99-dns-auto-ar.conf)."
  else
    echo -e "${BLUE}معلومة:${NC} إعادة تشغيل خدمة systemd-resolved..."
    if ! sudo systemctl restart systemd-resolved; then
      echo -e "${RED}خطأ:${NC} فشل إعادة تشغيل systemd-resolved. تأكد من أن الخدمة مثبتة ونشطة."
    else
      echo -e "${BLUE}معلومة:${NC} مسح ذاكرة التخزين المؤقت لـ DNS..."
      sudo systemd-resolve --flush-caches 2>/dev/null || true
      echo -e "${GREEN}نجاح:${NC} تم ضبط خوادم DNS وإعادة تشغيل الخدمة."
    fi
  fi

  echo -e "${BLUE}معلومة (11/12):${NC} التحقق من خدمة irqbalance وتمكينها (إذا كان عدد الأنوية > 1)..."
  if [[ "$CPU_CORES" -gt 1 ]]; then
      echo -e "${BLUE}معلومة:${NC} تم اكتشاف أكثر من نواة واحدة (${CPU_CORES}). خدمة irqbalance مفيدة."
      if install_pkg_arch "irqbalance" false; then
          if systemctl list-unit-files | grep -q irqbalance.service; then
              echo -e "${BLUE}معلومة:${NC} جاري تفعيل وبدء خدمة irqbalance..."
              if ! sudo systemctl enable --now irqbalance; then
                  if systemctl is-active --quiet irqbalance; then
                     echo -e "${GREEN}نجاح:${NC} خدمة irqbalance نشطة بالفعل."
                  else
                     echo -e "${YELLOW}تحذير:${NC} فشل تفعيل أو بدء خدمة irqbalance. تأكد من عدم وجود تعارضات."
                  fi
              else
                  echo -e "${GREEN}نجاح:${NC} تم تفعيل وبدء خدمة irqbalance."
              fi
          else
               echo -e "${YELLOW}تحذير:${NC} ملف خدمة irqbalance.service غير موجود حتى بعد التثبيت. لا يمكن إدارتها."
          fi
      else
           echo -e "${BLUE}معلومة:${NC} تم تخطي إدارة خدمة irqbalance (فشل التثبيت)."
      fi
  else
      echo -e "${BLUE}معلومة:${NC} تم اكتشاف نواة واحدة أو لم يتم تحديد العدد. خدمة irqbalance ليست ضرورية. تم تخطي التثبيت والتمكين."
  fi

  echo -e "${BLUE}معلومة (12/12):${NC} إجراء اختبار سرعة اختياري..."
  if install_pkg_arch "speedtest-cli" false; then
       if ! command -v speedtest-cli >/dev/null; then
           echo -e "${YELLOW}تحذير:${NC} لم يتم العثور على speedtest-cli أو فشل التثبيت. تم تخطي اختبار السرعة."
       else
           echo -e "${BLUE}معلومة:${NC} جاري إجراء اختبار السرعة (قد يستغرق بعض الوقت)..."
           if ! speedtest-cli --secure; then
             echo -e "${YELLOW}تحذير:${NC} فشل إكمال اختبار السرعة. تحقق من اتصالك بالإنترنت."
           else
             echo -e "${GREEN}نجاح:${NC} اكتمل اختبار السرعة."
           fi
       fi
  else
      echo -e "${BLUE}معلومة:${NC} تم تخطي اختبار السرعة (فشل تثبيت speedtest-cli)."
  fi

  echo -e "${GREEN}--- ✅ اكتمل تطبيق تحسينات الشبكة ---${NC}"
}

revert_optimizations() {
  echo -e "${BLUE}--- بدأ استعادة الإعدادات الافتراضية للشبكة ---${NC}"

  echo -e "${BLUE}معلومة (1/10):${NC} استعادة MTU الافتراضي (1500)..."
  sudo ip link set "$IFACE" mtu 1500 || echo -e "${YELLOW}تحذير:${NC} فشل استعادة MTU الافتراضي."

  echo -e "${BLUE}معلومة (2/10):${NC} استعادة حجم حلقات RX/TX الافتراضي (256)..."
  sudo ethtool -G "$IFACE" rx 256 tx 256 || echo -e "${YELLOW}تحذير:${NC} فشل استعادة حلقات RX/TX الافتراضية."

  echo -e "${BLUE}معلومة (3/10):${NC} تعطيل ميزات Offloading..."
  sudo ethtool -K "$IFACE" tso off gso off gro off || echo -e "${YELLOW}تحذير:${NC} فشل تعطيل ميزات Offloading."

  echo -e "${BLUE}معلومة (4/10):${NC} استعادة طول قائمة انتظار الإرسال الافتراضي (1000)..."
  sudo ip link set dev "$IFACE" txqueuelen 1000 || echo -e "${YELLOW}تحذير:${NC} فشل استعادة txqueuelen الافتراضي."

  echo -e "${BLUE}معلومة (5/10):${NC} تعطيل RPS..."
  rps_path="/sys/class/net/$IFACE/queues/rx-0/rps_cpus"
  if [ -f "$rps_path" ]; then
      echo 0 | sudo tee "$rps_path" >/dev/null || echo -e "${YELLOW}تحذير:${NC} فشل تعطيل RPS."
  fi

  echo -e "${BLUE}معلومة (6/10):${NC} استعادة قيم Coalesce الافتراضية..."
  if sudo ethtool -c "$IFACE" 2>/dev/null | grep -qi 'Coalesce'; then
      sudo ethtool -C "$IFACE" rx-usecs 0 tx-usecs 0 || echo -e "${YELLOW}تحذير:${NC} فشل استعادة قيم Coalesce الافتراضية."
  fi

  echo -e "${BLUE}معلومة (7/10):${NC} إزالة ملف إعدادات sysctl المخصص..."
  sudo rm -f /etc/sysctl.d/99-net-optimize-auto-ar.conf
  echo -e "${BLUE}معلومة:${NC} تطبيق إعدادات sysctl النظام..."
  sudo sysctl --system || echo -e "${YELLOW}تحذير:${NC} فشل إعادة تحميل إعدادات sysctl."

  echo -e "${BLUE}معلومة (8/10):${NC} إزالة ملف إعدادات DNS المخصص..."
  sudo rm -f /etc/systemd/resolved.conf.d/99-dns-auto-ar.conf
  echo -e "${BLUE}معلومة:${NC} إعادة تشغيل خدمة systemd-resolved..."
  sudo systemctl restart systemd-resolved || echo -e "${YELLOW}تحذير:${NC} فشل إعادة تشغيل systemd-resolved."
  sudo systemd-resolve --flush-caches 2>/dev/null || true

  echo -e "${BLUE}معلومة (9/10):${NC} إيقاف وتعطيل خدمة irqbalance..."
   if pacman -Q irqbalance &>/dev/null; then
       if systemctl list-unit-files | grep -q irqbalance.service; then
           sudo systemctl disable --now irqbalance 2>/dev/null || echo -e "${YELLOW}تحذير:${NC} فشل إيقاف أو تعطيل خدمة irqbalance."
       fi
   fi

  if [[ -n "$DRIVER" ]]; then
      echo -e "${BLUE}معلومة (10/10):${NC} محاولة إعادة تحميل التعريف $DRIVER بالإعدادات الافتراضية..."
      sudo modprobe -r "$DRIVER" 2>/dev/null
      sudo modprobe "$DRIVER" 2>/dev/null || echo -e "${YELLOW}تحذير:${NC} فشل إعادة تحميل التعريف $DRIVER."
  fi

  echo -e "${BLUE}معلومة:${NC} إزالة ملف تعطيل توفير طاقة الواي فاي..."
  sudo rm -f /etc/NetworkManager/conf.d/99-wifi-powersave-off-auto-ar.conf
  echo -e "${BLUE}معلومة:${NC} إعادة تشغيل NetworkManager..."
  sudo systemctl restart NetworkManager || echo -e "${YELLOW}تحذير:${NC} فشل إعادة تشغيل NetworkManager."

  echo -e "${GREEN}--- ✅ اكتملت استعادة الإعدادات الافتراضية ---${NC}"
}

# --- بداية التنفيذ ---

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}خطأ:${NC} يجب تشغيل هذا السكربت باستخدام صلاحيات الجذر (sudo)."
   exit 1
fi

echo -e "${BLUE}معلومة:${NC} التحقق من الأدوات الأساسية..."
install_pkg_arch "iproute2" true
install_pkg_arch "ethtool" true
install_pkg_arch "procps-ng" false # لتوفير أمر nproc (عادة يكون مثبتًا)

get_hardware_specs
get_network_info

action="apply"
if [[ "$1" == "--reverse" ]]; then
  action="revert"
fi
echo -e "${BLUE}معلومة:${NC} الإجراء المطلوب: ${YELLOW}$action${NC}"

if [[ "$action" == "apply" ]]; then
  apply_optimizations
elif [[ "$action" == "revert" ]]; then
  revert_optimizations
else
  echo -e "${RED}خطأ:${NC} إجراء غير معروف '$action'. استخدم 'apply' للتطبيق أو 'revert' للاستعادة."
  exit 1
fi

echo "===== الانتهاء: $(date '+%Y-%m-%d %H:%M:%S') ====="
exit 0
