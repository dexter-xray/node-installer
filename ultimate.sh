```bash
clear
echo "=================================================="
echo " Скрипт сделан: Dexter | @IamLeonKennedy"
echo " (Версия: TLS + BBR-X + Auto-renew) "
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

echo "[1/8] Оптимизация сети (BBR)..."

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

echo "[2/8] Обновление системных пакетов..."
apt-get update -y && apt-get upgrade -y

echo "[3/8] Установка системных компонентов..."
apt-get install -y irqbalance ethtool curl cron

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
  apt-get install certbot -y
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
echo "BBR Extended: АКТИВИРОВАН"
echo "TLS: НАСТРОЕН"
echo "Автопродление SSL: НАСТРОЕНО"
echo "Сертификаты привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="
```
