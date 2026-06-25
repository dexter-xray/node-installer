#!/bin/bash

clear
echo "=================================================="
echo " Скрипт сделан: Dexter | @IamLeonKennedy"
echo " (Версия: TLS + BBR-X + Net-Shield + Auto-renew) "
echo "=================================================="
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Пожалуйста, запустите скрипт с правами root (через sudo)."
  exit 1
fi

while [ -z "$DOMAIN" ]; do
  echo -n "Введите ваш домен (например, example.com): "
  read DOMAIN < /dev/tty
  if [ -z "$DOMAIN" ]; then
    echo "Домен не может быть пустым."
  fi
done

while [ -z "$EMAIL" ]; do
  echo -n "Введите ваш Email (для уведомлений Certbot): "
  read EMAIL < /dev/tty
  if [ -z "$EMAIL" ]; then
    echo "Email не может быть пустым."
  fi
done

while [ -z "$SECRET_KEY" ]; do
  echo -n "Введите Secret Key из панели Remnawave: "
  read SECRET_KEY < /dev/tty
  if [ -z "$SECRET_KEY" ]; then
    echo "Ключ не может быть пустым. Попробуйте еще раз."
  fi
done

echo -n "На каком порту разместить ноду? [По умолчанию: 2222]: "
read NODE_PORT < /dev/tty
NODE_PORT=${NODE_PORT:-2222}

echo -n "На каком порту будет принимать подключения нода? [По умолчанию: 443]: "
read XRAY_PORT < /dev/tty
XRAY_PORT=${XRAY_PORT:-443}

echo -n "На каком порту работает SSH? [По умолчанию: 22]: "
read SSH_PORT < /dev/tty
SSH_PORT=${SSH_PORT:-22}

echo ""
echo "--------------------------------------------------"
echo "Начало настройки системы..."
echo "--------------------------------------------------"

echo "[1/9] Оптимизация сети (BBR)..."

cat > /etc/sysctl.d/99-remnanode.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.ip_local_port_range=10000 65535
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
fs.file-max=2097152
fs.nr_open=2097152
EOF

modprobe tcp_bbr 2>/dev/null || true
sysctl --system > /dev/null 2>&1

mkdir -p /etc/security/limits.d

cat > /etc/security/limits.d/remnanode.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

echo "Оптимизация сети применена."

echo "[2/9] Обновление системных пакетов..."
apt-get update -y && apt-get upgrade -y

echo "[3/9] Установка системных компонентов..."
apt-get install -y irqbalance ethtool curl cron nftables

systemctl enable irqbalance > /dev/null 2>&1
systemctl start irqbalance > /dev/null 2>&1

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi

if ! command -v docker &> /dev/null; then
  echo "[4/9] Docker не найден. Установка официального Docker..."
  curl -fsSL https://docker.com | sh
else
  echo "[4/9] Docker уже установлен."
fi

echo "[5/9] Проверка и установка Certbot..."
if ! command -v certbot &> /dev/null; then
  apt-get install certbot -y
fi

echo "[6/9] Запрос SSL-сертификата от Let's Encrypt для $DOMAIN..."
certbot certonly --standalone \
  --preferred-challenges http \
  -d "$DOMAIN" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  echo ""
  echo "ОШИБКА: Не удалось выпустить SSL-сертификат."
  exit 1
fi

echo "[7/9] Настройка firewall Net-Shield..."

cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0;
        policy drop;
        iif lo accept
        ct state established,related accept
        tcp dport $SSH_PORT accept
        tcp dport 80 accept
        tcp dport $NODE_PORT accept
        udp dport $NODE_PORT accept
        tcp dport $XRAY_PORT accept
        udp dport $XRAY_PORT accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        tcp flags & (fin|syn) == (fin|syn) drop
        tcp flags & (syn|rst) == (syn|rst) drop
        tcp flags & (fin|rst) == (fin|rst) drop
        tcp flags == 0x0 drop
        counter drop
    }
    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }
    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}
EOF

systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables

echo "Firewall настроен."

echo "[8/9] Настройка Cron для автоматического продления..."
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'docker restart remnanode' >> /var/log/certbot-renew.log 2>&1") | crontab -
systemctl enable cron > /dev/null 2>&1
systemctl start cron > /dev/null 2>&1

echo "[9/9] Создание директории и docker-compose.yml..."
mkdir -p /opt/remnanode
cd /opt/remnanode

cat <<EOF > docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="$SECRET_KEY"
    volumes:
      - /etc/letsencrypt/live/$DOMAIN/fullchain.pem:/var/lib/remnawave/configs/xray/ssl/server.crt:ro
      - /etc/letsencrypt/live/$DOMAIN/privkey.pem:/var/lib/remnawave/configs/xray/ssl/server.key:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF

echo "Запуск контейнера remnanode..."
docker compose up -d

echo ""
echo "==================================================================="
echo "Установка успешно завершена!"
echo "Нода слушает порт: $NODE_PORT"
echo "Нода принимает подключения: $XRAY_PORT , $XRAY_PORTE"
echo "Разрешённый порт SSH: $SSH_PORT"
echo "BBR Extended: АКТИВИРОВАН"
echo "Net-Shield: АКТИВИРОВАН"
echo "==================================================================="
echo "TLS: НАСТРОЕН"
echo "Автопродление SSL: НАСТРОЕНО"
echo "Сертификаты привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="
