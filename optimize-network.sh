#!/usr/bin/env bash

set -Eeuo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-vpn-performance.conf"
BBR_MODULE_FILE="/etc/modules-load.d/bbr.conf"
LIMITS_FILE="/etc/security/limits.d/99-vpn.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-vpn-limits.conf"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ошибка: запустите скрипт от root:"
    echo "sudo bash $0"
    exit 1
fi

echo "============================================================"
echo " Оптимизация сети и включение BBR для Linux "
echo "============================================================"

# ------------------------------------------------------------
# 1. Проверка наличия модуля BBR
# ------------------------------------------------------------

echo "[1/6] Проверка поддержки BBR..."

if ! modinfo tcp_bbr >/dev/null 2>&1; then
    echo "Ошибка: модуль tcp_bbr отсутствует в текущем ядре."
    echo "Текущее ядро: $(uname -r)"
    exit 1
fi

# ------------------------------------------------------------
# 2. Постоянная загрузка модуля BBR
# ------------------------------------------------------------

echo "[2/6] Включение модуля tcp_bbr..."

cat > "${BBR_MODULE_FILE}" <<'EOF'
tcp_bbr
EOF

modprobe tcp_bbr

# ------------------------------------------------------------
# 3. Профиль сетевой оптимизации
# ------------------------------------------------------------

echo "[3/6] Создание профиля сетевой оптимизации..."

cat > "${SYSCTL_FILE}" <<'EOF'
# ============================================================
# Ubuntu 24.04 LTS VPN network optimization
# ============================================================

# Маршрутизация VPN-трафика
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# BBR и Fair Queue
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Очереди входящих пакетов и соединений
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535

# Сетевые буферы
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 4194304

# TCP-буферы: минимум, значение по умолчанию, максимум
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_moderate_rcvbuf = 1

# UDP-буферы для WireGuard, AmneziaWG и OpenVPN UDP
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Очередь незавершённых TCP-соединений
net.ipv4.tcp_max_syn_backlog = 32768

# Повторное использование исходящих TIME_WAIT-соединений
net.ipv4.tcp_tw_reuse = 1

# Обход проблем с Path MTU Discovery
net.ipv4.tcp_mtu_probing = 1

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# Не сохранять устаревшие метрики маршрутов
net.ipv4.tcp_no_metrics_save = 1

# TCP Keepalive
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Мягкая reverse-path проверка для VPN и policy routing
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Запрет ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Запрет source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Защита от SYN flood
net.ipv4.tcp_syncookies = 1

# Глобальные лимиты файловых дескрипторов
fs.file-max = 2097152
fs.nr_open = 2097152
EOF

# ------------------------------------------------------------
# 4. Лимиты пользовательских процессов
# ------------------------------------------------------------

echo "[4/6] Увеличение лимитов процессов..."

cat > "${LIMITS_FILE}" <<'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     1048576
*    hard    nproc     1048576

root soft    nofile    1048576
root hard    nofile    1048576
root soft    nproc     1048576
root hard    nproc     1048576
EOF

mkdir -p "${SYSTEMD_LIMITS_DIR}"

cat > "${SYSTEMD_LIMITS_FILE}" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultTasksMax=infinity
EOF

# ------------------------------------------------------------
# 5. Применение настроек
# ------------------------------------------------------------

echo "[5/6] Применение параметров ядра..."

sysctl --system >/dev/null
systemctl daemon-reexec

# ------------------------------------------------------------
# 6. Проверка
# ------------------------------------------------------------

echo "[6/6] Проверка результата..."

BBR_STATUS="$(sysctl -n net.ipv4.tcp_congestion_control)"
QDISC_STATUS="$(sysctl -n net.core.default_qdisc)"
FORWARD_STATUS="$(sysctl -n net.ipv4.ip_forward)"

echo
echo "============================================================"
echo " Оптимизация завершена"
echo "============================================================"
echo "TCP congestion control : ${BBR_STATUS}"
echo "Default qdisc          : ${QDISC_STATUS}"
echo "IPv4 forwarding        : ${FORWARD_STATUS}"
echo "File descriptor limit  : $(sysctl -n fs.file-max)"
echo "Kernel                  : $(uname -r)"
echo

if [[ "${BBR_STATUS}" == "bbr" ]] && [[ "${QDISC_STATUS}" == "fq" ]]; then
    echo "BBR успешно включён."
else
    echo "Внимание: BBR или fq не активировались."
    exit 1
fi

if lsmod | grep -q '^tcp_bbr'; then
    echo "Модуль tcp_bbr загружен."
else
    echo "Внимание: модуль tcp_bbr не отображается в lsmod."
fi

echo
echo "Для применения новых лимитов ко всем службам рекомендуется"
echo "перезагрузить сервер командой:"
echo
echo "    sudo reboot"
echo
