#!/bin/bash

clear
echo "=================================================="
echo " Скрипт сделан: Dexter | @IamLeonKennedy"
echo " (Версия: TLS + BBR + Auto-renew) "
echo "=================================================="
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Пожалуйста, запустите скрипт с правами root (через sudo)."
  exit 1
fi

while [ -z "$DOMAIN" ]; do
  read -p "Введите ваш домен (например, example.com): " DOMAIN </dev/tty
  if [ -z "$DOMAIN" ]; then
    echo "Домен не может быть пустым."
  fi
done

while [ -z "$EMAIL" ]; do
  read -p "Введите ваш Email (для уведомлений Certbot): " EMAIL </dev/tty
  if [ -z "$EMAIL" ]; then
    echo "Email не может быть пустым."
  fi
done

while [ -z "$SECRET_KEY" ]; do
  read -p "Введите Secret Key из панели Remnawave: " SECRET_KEY </dev/tty
  if [ -z "$SECRET_KEY" ]; then
    echo "Ключ не может быть пустым. Попробуйте еще раз."
  fi
done

read -p "На каком порту разместить ноду? [По умолчанию: 2222]: " NODE_PORT </dev/tty
NODE_PORT=${NODE_PORT:-2222}

clear
echo ""
echo "Начало настройки системы..."
echo "--------------------------------------------------"

echo "[1/8] Оптимизация сети и включение BBR..."

BBR_MODULE_FILE="/etc/modules-load.d/bbr.conf"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-performance.conf"
LIMITS_FILE="/etc/security/limits.d/99-vpn.conf"
SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/99-vpn-limits.conf"

if ! modinfo tcp_bbr >/dev/null 2>&1; then
  echo "Ошибка: модуль tcp_bbr отсутствует в текущем ядре: $(uname -r)"
  exit 1
fi

cat > "$BBR_MODULE_FILE" <<'EOF'
tcp_bbr
EOF

modprobe tcp_bbr

cat > "$SYSCTL_FILE" <<'EOF'
# Ubuntu 24.04 LTS VPN network optimization

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

# UDP-буферы
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1

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

# Глобальные лимиты файловых дескрипторов
fs.file-max = 2097152
fs.nr_open = 2097152
EOF

sysctl --system >/dev/null

mkdir -p /etc/security/limits.d
cat > "$LIMITS_FILE" <<'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     1048576
*    hard    nproc     1048576
root soft    nofile    1048576
root hard    nofile    1048576
root soft    nproc     1048576
root hard    nproc     1048576
EOF

mkdir -p "$SYSTEMD_LIMITS_DIR"
cat > "$SYSTEMD_LIMITS_FILE" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultTasksMax=infinity
EOF

systemctl daemon-reexec

if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ] || \
   [ "$(sysctl -n net.core.default_qdisc)" != "fq" ]; then
  echo "Ошибка: BBR или fq не активировались."
  exit 1
fi

echo "Оптимизация сети применена. BBR и fq активны."

# ЖЕСТКИЙ ЗАПРЕТ НА ДИАЛОГОВЫЕ ОКНА (Спасает вывод терминала от зависания)
export DEBIAN_FRONTEND=noninteractive
export UCFR_FORCE_CONFFOLD=1

echo "[2/8] Обновление системных пакетов..."
apt-get update -y && apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "[3/8] Установка системных компонентов..."
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y irqbalance ethtool curl cron

systemctl enable irqbalance > /dev/null 2>&1
systemctl start irqbalance > /dev/null 2>&1

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi

if ! command -v docker &> /dev/null; then
  echo "[4/8] Docker не найден. Установка официального Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[4/8] Docker уже установлен."
fi

echo "[5/8] Проверка и установка Certbot..."
if ! command -v certbot &> /dev/null; then
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install certbot -y
fi

echo "[6/8] Запрос SSL-сертификата от Let's Encrypt для $DOMAIN..."
echo "Убедитесь, что порт 80 открыт и домен направлен на IP этого сервера!"
echo ""

certbot certonly --standalone \
  --preferred-challenges http \
  -d "$DOMAIN" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  echo ""
  echo "ОШИБКА: Не удалось выпустить SSL-сертификат."
  echo "Проверьте, направлен ли домен на этот IP и не заблокирован ли порт 80."
  exit 1
fi


echo "[7/8] Настройка Cron для автоматического продления..."
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'docker restart remnanode' >> /var/log/certbot-renew.log 2>&1") | crontab -

systemctl enable cron > /dev/null 2>&1
systemctl start cron > /dev/null 2>&1

echo "[8/8] Создание директории и docker-compose.yml..."
mkdir -p /opt/remnanode
cd /opt/remnanode

cat <<EOF > docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="$SECRET_KEY"
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF

echo "Запуск контейнера remnanode..."
docker compose up -d

echo ""
echo "==================================================================="
echo "Установка успешно завершена!"
echo "Нода слушает порт: $NODE_PORT"
echo "NET-ADMIN : Active"
echo "Remnanode Version : Latest"
echo "BBR + оптимизация сети: АКТИВИРОВАНЫ"
echo "==================================================================="
echo "TLS: НАСТРОЕН"
echo "Автопродление SSL: НАСТРОЕНО"
echo "Сертификаты привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="
