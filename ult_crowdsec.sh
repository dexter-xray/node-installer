#!/bin/bash

clear
echo "=================================================="
echo " Скрипт сделан: Dexter | @IamLeonKennedy"
echo " (Версия: TLS + BBR + CrowdSec + Auto-renew) "
echo "=================================================="
echo ""

if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: запустите скрипт от root через sudo или после команды: su -"
  exit 1
fi

if [ ! -r /etc/os-release ]; then
  echo "Ошибка: не удалось определить операционную систему."
  exit 1
fi

. /etc/os-release

if ! { [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; } && \
   ! { [ "${ID:-}" = "debian" ] && { [ "${VERSION_ID:-}" = "12" ] || [ "${VERSION_ID:-}" = "13" ]; }; }; then
  echo "Ошибка: поддерживаются только Ubuntu 24.04 LTS, Debian 12 и Debian 13."
  echo "Обнаружено: ${PRETTY_NAME:-неизвестная система}"
  exit 1
fi

echo "Обнаружена поддерживаемая система: ${PRETTY_NAME}"

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

while true; do
  read -r -p "На каком порту разместить ноду? [По умолчанию: 2222]: " NODE_PORT </dev/tty
  NODE_PORT=${NODE_PORT:-2222}

  if [[ "$NODE_PORT" =~ ^[0-9]+$ ]] && [ "$NODE_PORT" -ge 1 ] && [ "$NODE_PORT" -le 65535 ]; then
    break
  fi

  echo "Ошибка: укажите порт от 1 до 65535."
done

CURRENT_SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
SSH_PORT="$CURRENT_SSH_PORT"
CHANGE_SSH_PORT="no"

while true; do
  read -r -p "Перенести SSH с порта $CURRENT_SSH_PORT на другой порт? [y/N]: " SSH_ANSWER </dev/tty
  case "$SSH_ANSWER" in
    [yY]|[yY][eE][sS]|[дД]|[дД][аА])
      CHANGE_SSH_PORT="yes"
      break
      ;;
    ""|[nN]|[nN][oO]|[нН]|[нН][еЕ][тТ])
      break
      ;;
    *)
      echo "Введите y/yes/да или n/no/нет."
      ;;
  esac
done

if [ "$CHANGE_SSH_PORT" = "yes" ]; then
  while true; do
    read -r -p "Введите новый SSH-порт (1024-65535): " SSH_PORT </dev/tty

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
      echo "Ошибка: укажите порт от 1024 до 65535."
      continue
    fi

    if [ "$SSH_PORT" -eq "$NODE_PORT" ] || [ "$SSH_PORT" -eq 80 ]; then
      echo "Ошибка: порт $SSH_PORT уже зарезервирован этим скриптом."
      continue
    fi

    break
  done

  echo "Важно: убедитесь, что TCP-порт $SSH_PORT разрешён в firewall панели VPS/облака."
fi

clear
echo ""
echo "Начало настройки системы..."
echo "--------------------------------------------------"

echo "[1/10] Оптимизация сети и включение BBR..."

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
# Ubuntu 24.04 LTS / Debian 12 VPN network optimization

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

echo "[2/10] Обновление системных пакетов..."
apt-get update -y

echo "[3/10] Установка системных компонентов..."
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y irqbalance ethtool curl cron nftables

systemctl enable irqbalance > /dev/null 2>&1
systemctl start irqbalance > /dev/null 2>&1

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi

if ! command -v docker &> /dev/null; then
  echo "[4/10] Docker не найден. Установка официального Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[4/10] Docker уже установлен."
fi

echo "[5/10] Настройка SSH..."

if [ "$CHANGE_SSH_PORT" = "yes" ]; then
  SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
  SSH_DROPIN_FILE="$SSH_DROPIN_DIR/00-remnanode-port.conf"
  SSH_DROPIN_BACKUP=""

  mkdir -p "$SSH_DROPIN_DIR"
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"

  if [ -f "$SSH_DROPIN_FILE" ]; then
    SSH_DROPIN_BACKUP=$(mktemp)
    cp -a "$SSH_DROPIN_FILE" "$SSH_DROPIN_BACKUP"
  fi

  cat > "$SSH_DROPIN_FILE" <<EOF
# Managed by ult_crowdsec.sh
Port $SSH_PORT
EOF

  rollback_ssh_port() {
    if [ -n "$SSH_DROPIN_BACKUP" ] && [ -f "$SSH_DROPIN_BACKUP" ]; then
      cp -a "$SSH_DROPIN_BACKUP" "$SSH_DROPIN_FILE"
    else
      rm -f "$SSH_DROPIN_FILE"
    fi

    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket; then
      systemctl restart ssh.socket || true
    fi
    systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
  }

  if ! sshd -t; then
    rollback_ssh_port
    echo "Ошибка конфигурации SSH. Изменение порта отменено."
    exit 1
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "$SSH_PORT/tcp"
  fi

  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh

  sleep 1
  if ! ss -H -ltn | awk -v port=":$SSH_PORT" '$4 ~ (port "$") {found=1} END {exit !found}'; then
    rollback_ssh_port
    echo "Ошибка: SSH не начал слушать порт $SSH_PORT. Изменение автоматически отменено."
    exit 1
  fi

  rm -f "$SSH_DROPIN_BACKUP"
  echo "SSH перенесён на TCP-порт $SSH_PORT. Текущую SSH-сессию не закрывайте до проверки нового подключения."
else
  echo "SSH оставлен на текущем порту $SSH_PORT."
fi

echo "[6/10] Установка и настройка CrowdSec..."

# Удаляем Fail2Ban, если он остался от предыдущего запуска.
# CrowdSec и Fail2Ban не должны одновременно управлять блокировками.
if dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q "install ok installed"; then
  systemctl disable --now fail2ban >/dev/null 2>&1 || true
  apt-get purge -y fail2ban
fi
rm -rf /etc/fail2ban

apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y \
  ca-certificates gnupg

if ! command -v crowdsec >/dev/null 2>&1; then
  curl -fsSL https://install.crowdsec.net | sh
  apt-get update -y
fi

apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y \
  crowdsec crowdsec-firewall-bouncer-nftables

if command -v cscli >/dev/null 2>&1; then
  cscli collections install crowdsecurity/sshd >/dev/null 2>&1 || true
fi

systemctl enable --now crowdsec
systemctl restart crowdsec

# Регистрируем bouncer заново и записываем действующий ключ Local API.
# Это предотвращает ошибку: API error: access forbidden.
BOUNCER_NAME="crowdsec-firewall-bouncer"
BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"

systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true
cscli bouncers delete "$BOUNCER_NAME" >/dev/null 2>&1 || true
BOUNCER_API_KEY=$(cscli bouncers add "$BOUNCER_NAME" -o raw)

if [ -z "$BOUNCER_API_KEY" ] || [ ! -f "$BOUNCER_CONFIG" ]; then
  echo "Ошибка: не удалось зарегистрировать CrowdSec Firewall Bouncer."
  exit 1
fi

python3 - "$BOUNCER_CONFIG" "$BOUNCER_API_KEY" <<'PYCODE'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
api_key = sys.argv[2]
content = config_path.read_text()
updated, count = re.subn(
    r"(?m)^api_key\s*:\s*.*$",
    f"api_key: {api_key}",
    content,
    count=1,
)
if count != 1:
    raise SystemExit("В конфигурации bouncer не найден параметр api_key")
config_path.write_text(updated)
PYCODE

chmod 600 "$BOUNCER_CONFIG"
systemctl enable crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer

if ! systemctl is-active --quiet crowdsec; then
  echo "Ошибка: служба CrowdSec не запустилась."
  systemctl status crowdsec --no-pager -l || true
  exit 1
fi

if ! systemctl is-active --quiet crowdsec-firewall-bouncer; then
  echo "Ошибка: CrowdSec Firewall Bouncer не запустился."
  systemctl status crowdsec-firewall-bouncer --no-pager -l || true
  exit 1
fi

echo "CrowdSec и firewall bouncer установлены и запущены."

echo "[7/10] Проверка и установка Certbot..."
if ! command -v certbot &> /dev/null; then
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install certbot -y
fi

echo "[8/10] Запрос SSL-сертификата от Let's Encrypt для $DOMAIN..."
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


echo "[9/10] Настройка Cron для автоматического продления..."
CRON_JOB="0 3 * * * certbot renew --post-hook 'docker restart remnanode' >> /var/log/certbot-renew.log 2>&1"
CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)
if ! printf '%s\n' "$CURRENT_CRONTAB" | grep -Fq "$CRON_JOB"; then
  { printf '%s\n' "$CURRENT_CRONTAB"; printf '%s\n' "$CRON_JOB"; } | sed '/^$/d' | crontab -
fi

systemctl enable cron > /dev/null 2>&1
systemctl start cron > /dev/null 2>&1

echo "[10/10] Создание директории и docker-compose.yml..."
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
echo "CrowdSec + firewall bouncer: АКТИВИРОВАНЫ"
echo "SSH-порт: $SSH_PORT"
echo "==================================================================="
echo "TLS: НАСТРОЕН"
echo "Автопродление SSL: НАСТРОЕНО"
echo "Сертификаты привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="
