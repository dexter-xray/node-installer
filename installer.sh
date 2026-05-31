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

echo "[1/8] Включение оптимизации сети BBR..."
if ! sysctl net.core.default_qdisc | grep -q "fq" || ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p > /dev/null
  echo "BBR успешно активирован!"
else
  echo "BBR уже был активирован ранее."
fi

echo "[2/8] Обновление системных пакетов..."
apt-get update -y && apt-get upgrade -y

if ! command -v docker &> /dev/null; then
  echo "[3/8] Docker не найден. Установка официального Docker..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[3/8] Docker уже установлен."
fi

echo "[4/8] Проверка и установка Certbot и Cron..."
if ! command -v certbot &> /dev/null; then
  apt-get install certbot -y
fi
apt-get install cron -y > /dev/null

echo "[5/8] Запрос SSL-сертификата от Let's Encrypt для $DOMAIN..."
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

echo "[6/8] Настройка Cron для автоматического продления..."
# Задача проверяет сертификат в 03:00 и перезапускает ноду только в случае реального обновления
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'docker restart remnanode' >> /var/log/certbot-renew.log 2>&1") | crontab -
systemctl enable cron > /dev/null 2>&1
systemctl start cron > /dev/null 2>&1

echo "[7/8] Создание директории /opt/remnanode..."
mkdir -p /opt/remnanode
cd /opt/remnanode

echo "[8/8] Генерация файла docker-compose.yml..."
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
echo "Оптимизация сети BBR: АКТИВИРОВАНА"
echo "Автопродление SSL: НАСТРОЕНО (проверка каждую ночь)"
echo "Сертификаты успешно привязаны к домену: $DOMAIN"
echo "==================================================================="
echo "ВАЖНО: В панели Remnawave при настройке Inbound TLS"
echo "для ЭТОЙ НОДЫ укажите следующие внутренние пути:"
echo "Путь к сертификату: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Путь к ключу: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo "==================================================================="