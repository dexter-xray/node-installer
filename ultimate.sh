clear
echo "================================================================="
echo " Скрипт сделан: Dexter | @IamLeonKennedy"
echo " (Версия: TLS + BBR + Auto-renew + Ultimate Kernel + Net Shield) "
echo "================================================================="
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

read -p "На каком порту разместить ноду (для связи с панелью)? [По умолчанию: 6767]: " NODE_PORT </dev/tty
NODE_PORT=${NODE_PORT:-6767}

read -p "Укажите РАБОЧИЙ порт VPN (который будет в Inbound) [По умолчанию: 47067]: " VPN_PORT </dev/tty
VPN_PORT=${VPN_PORT:-47067}

read -p "Укажите ваш текущий порт SSH [По умолчанию: 22]: " SSH_PORT </dev/tty
SSH_PORT=${SSH_PORT:-22}

clear
echo ""
echo "Начало настройки системы..."
echo "--------------------------------------------------"

echo "[1/9] Применение оптимизации ядра..."
cp /etc/sysctl.conf /etc/sysctl.conf.bak

declare -a params=(
  "net.core.default_qdisc" "net.core.netdev_max_backlog" "net.core.somaxconn" 
  "net.core.rmem_default" "net.core.wmem_default" "net.core.rmem_max" "net.core.wmem_max" "net.core.optmem_max"
  "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_fastopen" "net.ipv4.tcp_slow_start_after_idle" 
  "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_fin_timeout" "net.ipv4.tcp_keepalive_time" "net.ipv4.tcp_keepalive_intvl" 
  "net.ipv4.tcp_keepalive_probes" "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_max_tw_buckets" "net.ipv4.tcp_mtu_probing" 
  "net.ipv4.tcp_no_metrics_save" "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack" "net.ipv4.tcp_window_scaling" 
  "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_ecn" "net.ipv4.ip_local_port_range"
  "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min" "net.ipv4.ip_forward" "net.ipv4.conf.all.forwarding" 
  "net.ipv6.conf.all.forwarding" "net.netfilter.nf_conntrack_max" "net.nf_conntrack_max" 
  "net.netfilter.nf_conntrack_tcp_timeout_established" "net.netfilter.nf_conntrack_buckets" "net.ipv4.tcp_syncookies" 
  "net.ipv4.tcp_synack_retries" "net.ipv4.tcp_syn_retries" "net.ipv4.conf.all.rp_filter" "net.ipv4.conf.default.rp_filter" 
  "net.ipv4.conf.all.accept_source_route" "net.ipv4.conf.default.accept_source_route" "net.ipv4.conf.all.send_redirects" 
  "net.ipv4.conf.default.send_redirects" "net.ipv4.conf.all.accept_redirects" "net.ipv4.conf.default.accept_redirects" 
  "net.ipv4.conf.all.secure_redirects" "net.ipv4.icmp_echo_ignore_broadcasts" "net.ipv4.icmp_ignore_bogus_error_responses"
  "vm.swappiness" "vm.dirty_ratio" "vm.dirty_background_ratio" "vm.overcommit_memory" 
  "fs.file-max" "fs.nr_open" "fs.inotify.max_user_watches" "fs.inotify.max_user_instances"
)

for param in "${params[@]}"; do
  sed -i "/^${param}/d" /etc/sysctl.conf
done

cat <<EOF >> /etc/sysctl.conf

net.core.default_qdisc            = fq
net.core.netdev_max_backlog       = 250000
net.core.somaxconn                = 65535
net.core.rmem_default             = 2097152
net.core.wmem_default             = 2097152
net.core.rmem_max                 = 67108864
net.core.wmem_max                 = 67108864
net.core.optmem_max               = 65536

net.ipv4.tcp_congestion_control   = bbr
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse             = 1
net.ipv4.tcp_fin_timeout          = 15
net.ipv4.tcp_keepalive_time       = 300
net.ipv4.tcp_keepalive_intvl      = 30
net.ipv4.tcp_keepalive_probes     = 5
net.ipv4.tcp_max_syn_backlog      = 65535
net.ipv4.tcp_max_tw_buckets       = 2000000
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_no_metrics_save      = 1
net.ipv4.tcp_rfc1337              = 1
net.ipv4.tcp_sack                 = 1
net.ipv4.tcp_window_scaling       = 1
net.ipv4.tcp_rmem                 = 4096 87380 67108864
net.ipv4.tcp_wmem                 = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat        = 131072
net.ipv4.tcp_ecn                  = 1
net.ipv4.ip_local_port_range      = 10000 65535

net.ipv4.udp_rmem_min             = 8192
net.ipv4.udp_wmem_min             = 8192

net.ipv4.ip_forward               = 1
net.ipv4.conf.all.forwarding      = 1
net.ipv6.conf.all.forwarding      = 1

net.netfilter.nf_conntrack_max                  = 2000000
net.nf_conntrack_max                            = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_buckets              = 500000

net.ipv4.tcp_syncookies           = 1
net.ipv4.tcp_synack_retries       = 2
net.ipv4.tcp_syn_retries          = 2

net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

vm.swappiness                = 10
vm.dirty_ratio               = 10
vm.dirty_background_ratio    = 5
vm.overcommit_memory         = 1

fs.file-max                  = 2097152
fs.nr_open                   = 2097152
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192
EOF

# Применяем конфигурацию sysctl
sysctl -p > /dev/null
echo "Параметры ядра успешно оптимизированы!"

echo "[2/9] Обновление системных пакетов..."
apt-get update -y && apt-get upgrade -y

echo "[3/9] Настройка правил фильтрации IPTables..."
iptables -F
iptables -X

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport "$NODE_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$VPN_PORT" -j ACCEPT
iptables -A INPUT -p udp --dport "$VPN_PORT" -j ACCEPT

iptables -A INPUT -m conntrack --ctstate NEW -m recent --set --name PORTSCAN
iptables -A INPUT -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 3 --name PORTSCAN -j DROP

netfilter-persistent save > /dev/null 2>&1
echo "Умная защита портов успешно активирована!"

if ! command -v docker &> /dev/null; then
  echo "[4/9] Docker не найден. Установка официального Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[4/9] Docker уже установлен."
fi

echo "[5/9] Проверка и установка Certbot и Cron..."
if ! command -v certbot &> /dev/null; then
  apt-get install certbot -y
fi
apt-get install cron -y > /dev/null

echo "[6/9] Запрос SSL-сертификата от Let's Encrypt для $DOMAIN..."
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

echo "[7/9] Настройка Cron для автоматического продления..."
# Задача проверяет сертификат в 03:00 и перезапускает ноду только в случае реального обновления
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'docker restart remnanode' >> /var/log/certbot-renew.log 2>&1") | crontab -
systemctl enable cron > /dev/null 2>&1
systemctl start cron > /dev/null 2>&1

echo "[8/9] Создание директории /opt/remnanode..."
mkdir -p /opt/remnanode
cd /opt/remnanode

echo "[9/9] Генерация файла docker-compose.yml..."
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
echo "Установка успешно завершена по официальному гайду!"
echo "Нода слушает порт: $NODE_PORT"
echo "Рабочий порт для инбаунда VPN: $VPN_PORT"
echo ""
echo "Оптимизация ядра Ultimate Kernel: АКТИВИРОВАНА"
echo "Оптимизация сети BBR: АКТИВИРОВАНА"
echo "Умная защита от сканирования портов (Net Shield): АКТИВИРОВАНА"
echo ""
echo "Автопродление SSL: НАСТРОЕНО (проверка каждую ночь)"
echo "Сертификаты успешно привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "ВАЖНО: В панели Remnawave при настройке Inbound TLS"
echo "для ЭТОЙ НОДЫ укажите следующие внутренние пути:"
echo ""
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="