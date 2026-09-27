#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-remnanode.conf"
SELFSTEAL_PORT=9443
APT_LOCK_TIMEOUT=900

DOMAIN=""
EMAIL=""
SECRET_KEY=""
NODE_PORT=2222
CURRENT_SSH_PORT=22
SSH_PORT=22
SSH_LOGIN_USER=""
SSH_PUBLIC_KEY=""
INSTALL_CROWDSEC=false
CHANGE_SSH_PORT=false
ENABLE_KEY_ONLY=false
ENABLE_UFW=false
ENABLE_UNATTENDED_UPGRADES=false
ENABLE_NODE_AUTOUPDATE=false
PANEL_SOURCE=""

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf '\nОшибка: %s\n' "$*" >&2
  exit 1
}

apt_is_busy() {
  local lock

  if command -v fuser >/dev/null 2>&1; then
    for lock in \
      /var/lib/dpkg/lock-frontend \
      /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock \
      /var/lib/apt/lists/lock; do
      fuser "$lock" >/dev/null 2>&1 && return 0
    done
  fi

  pgrep -x apt >/dev/null 2>&1 ||
    pgrep -x apt-get >/dev/null 2>&1 ||
    pgrep -x dpkg >/dev/null 2>&1 ||
    pgrep -f '/usr/bin/unattended-upgrade' >/dev/null 2>&1
}

wait_for_apt_unlock() {
  local waited=0

  while apt_is_busy; do
    if ((waited == 0)); then
      echo "APT/dpkg занят другим процессом. Ожидаю освобождения блокировки..."
    fi
    if ((waited >= APT_LOCK_TIMEOUT)); then
      ps -eo pid,etime,cmd |
        grep -E '[a]pt(-get)?|[d]pkg|[u]nattended-upgrade' >&2 || true
      die "APT/dpkg не освободился за $APT_LOCK_TIMEOUT секунд."
    fi
    sleep 5
    ((waited += 5))
  done

  if ((waited > 0)); then
    echo "Блокировка APT/dpkg снята. Продолжаю установку."
  fi
}

apt_get() {
  wait_for_apt_unlock
  DEBIAN_FRONTEND=noninteractive \
    apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"
}

on_error() {
  local exit_code=$?
  printf '\nОшибка выполнения на строке %s. Код: %s\n' "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  exit "$exit_code"
}

trap on_error ERR

ask_yes_no() {
  local prompt=$1
  local default=${2:-no}
  local hint answer

  if [[ "$default" == "yes" ]]; then
    hint='[Y/n]'
  else
    hint='[y/N]'
  fi

  while true; do
    read -r -p "$prompt $hint: " answer </dev/tty
    case "${answer,,}" in
      y|yes|д|да)
        return 0
        ;;
      n|no|н|нет)
        return 1
        ;;
      "")
        [[ "$default" == "yes" ]]
        return
        ;;
      *)
        echo "Введите y/yes/да или n/no/нет."
        ;;
    esac
  done
}

read_required() {
  local variable_name=$1
  local prompt=$2
  local secret=${3:-false}
  local value=""

  while [[ -z "$value" ]]; do
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$prompt: " value </dev/tty
      echo
    else
      read -r -p "$prompt: " value </dev/tty
    fi
    [[ -n "$value" ]] || echo "Значение не может быть пустым."
  done

  printf -v "$variable_name" '%s' "$value"
}

validate_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

validate_domain() {
  local domain=$1
  [[ ${#domain} -le 253 ]] &&
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

read_port() {
  local variable_name=$1
  local prompt=$2
  local default=$3
  local min_port=${4:-1}
  local value

  while true; do
    read -r -p "$prompt [по умолчанию: $default]: " value </dev/tty
    value=${value:-$default}
    if validate_port "$value" && ((value >= min_port)); then
      printf -v "$variable_name" '%s' "$value"
      return
    fi
    echo "Укажите порт от $min_port до 65535."
  done
}

ensure_supported_os() {
  [[ $EUID -eq 0 ]] || die "запустите скрипт от root через sudo или su -."
  [[ -r /etc/os-release ]] || die "не удалось определить операционную систему."

  # shellcheck source=/dev/null
  . /etc/os-release

  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
    return
  fi
  if [[ "${ID:-}" == "debian" && ("${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13") ]]; then
    return
  fi

  die "поддерживаются Ubuntu 24.04 LTS, Debian 12 и Debian 13. Обнаружено: ${PRETTY_NAME:-неизвестно}."
}

find_public_key() {
  local preferred="$SCRIPT_DIR/ssh_key.pub"
  local -a candidates=()
  local selected=""

  if [[ -f "$preferred" ]]; then
    SSH_PUBLIC_KEY=$preferred
    return
  fi

  mapfile -d '' candidates < <(
    find "$SCRIPT_DIR" -maxdepth 1 -type f \
      \( -name '*.pub' -o -name 'authorized_keys' \) -print0 | sort -z
  )

  case "${#candidates[@]}" in
    0)
      die "рядом со скриптом не найден публичный ключ. Положите файл ssh_key.pub в $SCRIPT_DIR и запустите скрипт снова."
      ;;
    1)
      SSH_PUBLIC_KEY=${candidates[0]}
      ;;
    *)
      echo "Найдено несколько публичных ключей:"
      printf '  %s\n' "${candidates[@]}"
      while true; do
        read -r -p "Введите имя нужного файла: " selected </dev/tty
        [[ "$selected" != */* ]] || {
          echo "Укажите только имя файла из каталога скрипта."
          continue
        }
        if [[ -f "$SCRIPT_DIR/$selected" ]]; then
          SSH_PUBLIC_KEY="$SCRIPT_DIR/$selected"
          break
        fi
        echo "Файл не найден."
      done
      ;;
  esac
}

validate_public_key_file() {
  local key_file=$1
  local temp_key
  local found=false

  temp_key=$(mktemp)
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]]; then
      rm -f "$temp_key"
      die "файл $key_file содержит строку, не похожую на публичный OpenSSH-ключ."
    fi
    printf '%s\n' "$line" > "$temp_key"
    ssh-keygen -lf "$temp_key" >/dev/null 2>&1 || {
      rm -f "$temp_key"
      die "публичный ключ в $key_file не прошёл проверку ssh-keygen."
    }
    found=true
  done < "$key_file"
  rm -f "$temp_key"
  [[ "$found" == "true" ]] || die "в $key_file нет публичных ключей."
}

select_ssh_user() {
  local default_user
  local entered_user

  default_user=${SUDO_USER:-root}
  [[ "$default_user" != "root" ]] || default_user=root

  while true; do
    read -r -p "Для какого Linux-пользователя установить ключ? [по умолчанию: $default_user]: " entered_user </dev/tty
    SSH_LOGIN_USER=${entered_user:-$default_user}
    if getent passwd "$SSH_LOGIN_USER" >/dev/null; then
      return
    fi
    echo "Пользователь $SSH_LOGIN_USER не найден."
  done
}

install_authorized_key() {
  local user_entry home group authorized_keys line

  user_entry=$(getent passwd "$SSH_LOGIN_USER")
  home=$(cut -d: -f6 <<< "$user_entry")
  group=$(id -gn "$SSH_LOGIN_USER")
  [[ -d "$home" ]] || die "домашний каталог пользователя $SSH_LOGIN_USER не существует: $home"

  install -d -m 700 -o "$SSH_LOGIN_USER" -g "$group" "$home/.ssh"
  authorized_keys="$home/.ssh/authorized_keys"
  touch "$authorized_keys"
  chown "$SSH_LOGIN_USER:$group" "$authorized_keys"
  chmod 600 "$authorized_keys"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    grep -Fqx -- "$line" "$authorized_keys" || printf '%s\n' "$line" >> "$authorized_keys"
  done < "$SSH_PUBLIC_KEY"

  chown "$SSH_LOGIN_USER:$group" "$authorized_keys"
  chmod 600 "$authorized_keys"
  echo "Ключ установлен в $authorized_keys."
}

configure_ssh() {
  local backup=""
  local effective

  if [[ "$CHANGE_SSH_PORT" != "true" && "$ENABLE_KEY_ONLY" != "true" ]]; then
    echo "Конфигурация SSH не изменяется."
    return
  fi

  mkdir -p /etc/ssh/sshd_config.d
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$SSH_DROPIN" ]]; then
    backup=$(mktemp)
    cp -a "$SSH_DROPIN" "$backup"
  fi

  {
    echo "# Managed by $(basename "$SCRIPT_PATH")"
    if [[ "$CHANGE_SSH_PORT" == "true" ]]; then
      echo "Port $SSH_PORT"
    fi
    if [[ "$ENABLE_KEY_ONLY" == "true" ]]; then
      cat <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
    fi
  } > "$SSH_DROPIN"

  if ! sshd -t; then
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$SSH_DROPIN"
    else
      rm -f "$SSH_DROPIN"
    fi
    rm -f "$backup"
    die "новая конфигурация SSH не прошла sshd -t; изменения отменены."
  fi

  effective=$(sshd -T -C "user=$SSH_LOGIN_USER,host=$(hostname),addr=127.0.0.1")
  if [[ "$ENABLE_KEY_ONLY" == "true" ]]; then
    if ! grep -q '^pubkeyauthentication yes$' <<< "$effective" ||
      ! grep -q '^passwordauthentication no$' <<< "$effective" ||
      ! grep -q '^kbdinteractiveauthentication no$' <<< "$effective"; then
      if [[ -n "$backup" ]]; then
        cp -a "$backup" "$SSH_DROPIN"
      else
        rm -f "$SSH_DROPIN"
      fi
      rm -f "$backup"
      die "параметры входа только по ключу не стали эффективными; изменения SSH отменены."
    fi
  fi

  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  fi
  systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh

  sleep 1
  if ! ss -H -ltn | awk -v port=":$SSH_PORT" '$4 ~ (port "$") {found=1} END {exit !found}'; then
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$SSH_DROPIN"
    else
      rm -f "$SSH_DROPIN"
    fi
    systemctl daemon-reload
    systemctl restart ssh.socket >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || true
    rm -f "$backup"
    die "SSH не начал слушать порт $SSH_PORT; изменения отменены."
  fi

  rm -f "$backup"
  echo "SSH настроен. Не закрывайте текущую сессию до проверки нового входа."
}

configure_bbr() {
  local sysctl_file=/etc/sysctl.d/99-remnanode-performance.conf

  modinfo tcp_bbr >/dev/null 2>&1 || die "модуль tcp_bbr отсутствует в ядре $(uname -r)."
  printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/remnanode.conf
  modprobe tcp_bbr
  modprobe nf_conntrack

  cat > "$sysctl_file" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 4194304
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.netfilter.nf_conntrack_max = 262144
fs.file-max = 2097152
fs.nr_open = 2097152
EOF

  sysctl --system >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR не активировался."
  [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "fq не активировался."

  mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
  cat > /etc/security/limits.d/99-remnanode.conf <<'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
root soft    nofile    1048576
root hard    nofile    1048576
EOF
  cat > /etc/systemd/system.conf.d/99-remnanode.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultTasksMax=infinity
EOF
  systemctl daemon-reexec
}

install_docker() {
  local installer log_file
  local attempt=1
  local max_attempts=5
  local exit_code

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker и Compose уже установлены."
    return
  fi

  installer=$(mktemp)
  log_file=$(mktemp)
  curl -fsSL https://get.docker.com -o "$installer"

  while ((attempt <= max_attempts)); do
    wait_for_apt_unlock
    : > "$log_file"
    echo "Установка Docker: попытка $attempt из $max_attempts..."

    if sh "$installer" >"$log_file" 2>&1; then
      cat "$log_file"
      rm -f "$installer" "$log_file"
      docker compose version >/dev/null 2>&1 ||
        die "Docker Compose v2 не установился."
      return
    else
      exit_code=$?
      cat "$log_file" >&2
    fi

    if grep -Eqi \
      'Could not get lock|Unable to acquire.*lock|is another process using it' \
      "$log_file"; then
      echo "Установщик Docker столкнулся с блокировкой APT/dpkg."
      ((attempt += 1))
      if ((attempt <= max_attempts)); then
        wait_for_apt_unlock
        echo "Повторяю установку Docker после снятия блокировки."
        continue
      fi
    fi

    rm -f "$installer" "$log_file"
    die "установщик Docker завершился с кодом $exit_code."
  done

  rm -f "$installer" "$log_file"
  die "не удалось установить Docker после $max_attempts попыток."
}

install_caddy_selfsteal() {
  local pages_dir="$SCRIPT_DIR/selfsteal-pages"
  local fallback_page="$SCRIPT_DIR/index.html"
  local source_page=""
  local page
  local public_ipv4 dns_ipv4 dns_records caddy_key
  local -a candidates=()

  if [[ -d "$pages_dir" ]]; then
    while IFS= read -r -d '' page; do
      [[ -s "$page" ]] && candidates+=("$page")
    done < <(find "$pages_dir" -maxdepth 1 -type f -name '*.html' -print0 | sort -z)
  fi

  if ((${#candidates[@]} > 0)); then
    source_page=${candidates[RANDOM % ${#candidates[@]}]}
    echo "Случайно выбрана Selfsteal-заглушка: $(basename "$source_page")"
  elif [[ -s "$fallback_page" ]]; then
    source_page=$fallback_page
    echo "Папка selfsteal-pages пуста; используется $fallback_page."
  else
    die "нет заглушек: добавьте HTML-файлы в $pages_dir или положите index.html рядом со скриптом."
  fi

  public_ipv4=$(curl -4fsS --max-time 10 https://api.ipify.org || true)
  dns_records=$(getent ahostsv4 "$DOMAIN" || true)
  dns_ipv4=$(awk 'NR == 1 {first = $1} END {print first}' <<< "$dns_records")
  if [[ -z "$dns_ipv4" ]]; then
    die "домен $DOMAIN не имеет доступной A-записи."
  fi
  if [[ -n "$public_ipv4" && "$dns_ipv4" != "$public_ipv4" ]]; then
    echo "Предупреждение: $DOMAIN → $dns_ipv4, а публичный IPv4 сервера определяется как $public_ipv4."
    ask_yes_no "Продолжить несмотря на несовпадение DNS?" "no" ||
      die "исправьте A-запись домена и запустите скрипт снова."
  fi

  if [[ -n "$(ss -H -ltn '( sport = :80 )')" ]] &&
    ! systemctl is-active --quiet caddy; then
    ss -H -ltnp '( sport = :80 )' || true
    die "порт 80 занят не Caddy. Освободите его для ACME HTTP-01."
  fi

  apt_get install -y debian-keyring debian-archive-keyring apt-transport-https gpg
  caddy_key=$(mktemp)
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$caddy_key"
  gpg --dearmor --yes \
    -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$caddy_key"
  rm -f "$caddy_key"
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt_get update
  apt_get install -y caddy

  install -d -m 755 /var/www/selfsteal
  install -m 644 "$source_page" /var/www/selfsteal/index.html
  chown -R root:root /var/www/selfsteal

  cat > /etc/caddy/Caddyfile <<EOF
{
    auto_https disable_redirects
    email $EMAIL
}

(selfsteal_app) {
    route {
        handle /api/v1/status {
            header Content-Type "application/json; charset=utf-8"
            header Cache-Control "no-store"
            respond "{\"status\":\"ok\"}" 200
        }

        @api_v1 path /api/v1 /api/v1/*
        handle @api_v1 {
            header Content-Type "application/json; charset=utf-8"
            header Cache-Control "no-store"
            respond "{\"error\":\"Unknown user\"}" 404
        }

        handle {
            root * /var/www/selfsteal
            file_server
        }
    }
}

:80 {
    import selfsteal_app
}

$DOMAIN:$SELFSTEAL_PORT {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    import selfsteal_app
}
EOF

  caddy validate --config /etc/caddy/Caddyfile
  systemctl enable caddy
  systemctl restart caddy

  for _ in {1..12}; do
    if curl -fsS --max-time 10 \
      --resolve "$DOMAIN:$SELFSTEAL_PORT:127.0.0.1" \
      "https://$DOMAIN:$SELFSTEAL_PORT/" >/dev/null; then
      echo "Selfsteal-заглушка доступна на 127.0.0.1:$SELFSTEAL_PORT."
      return
    fi
    sleep 5
  done

  journalctl -u caddy --no-pager -n 50 >&2 || true
  die "Caddy не смог получить сертификат или запустить локальный HTTPS на порту $SELFSTEAL_PORT."
}

configure_ufw() {
  apt_get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'Caddy ACME HTTP-01'
  ufw allow 443/tcp comment 'Reality'

  if [[ -n "$PANEL_SOURCE" ]]; then
    python3 - "$PANEL_SOURCE" <<'PY'
import ipaddress
import sys
ipaddress.ip_network(sys.argv[1], strict=False)
PY
    ufw allow from "$PANEL_SOURCE" to any port "$NODE_PORT" proto tcp comment 'Remnawave Node API'
  else
    echo "Предупреждение: NODE_PORT будет открыт для всего интернета."
    ufw allow "$NODE_PORT/tcp" comment 'Remnawave Node API'
  fi

  ufw --force enable
  ufw status verbose
}

install_crowdsec() {
  local bouncer_name=crowdsec-firewall-bouncer
  local bouncer_config=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
  local api_key crowdsec_installer fail2ban_status

  fail2ban_status=$(dpkg-query -W -f='${db:Status-Abbrev}' fail2ban 2>/dev/null || true)
  if [[ "$fail2ban_status" == ii* ]]; then
    systemctl disable --now fail2ban >/dev/null 2>&1 || true
    apt_get purge -y fail2ban
    rm -rf /etc/fail2ban
  fi

  apt_get install -y ca-certificates gnupg
  if ! command -v crowdsec >/dev/null 2>&1; then
    crowdsec_installer=$(mktemp)
    curl -fsSL https://install.crowdsec.net -o "$crowdsec_installer"
    sh "$crowdsec_installer"
    rm -f "$crowdsec_installer"
    apt_get update
  fi
  apt_get install -y crowdsec crowdsec-firewall-bouncer-nftables

  cscli collections install crowdsecurity/sshd >/dev/null 2>&1 || true
  systemctl enable --now crowdsec

  systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true
  cscli bouncers delete "$bouncer_name" >/dev/null 2>&1 || true
  api_key=$(cscli bouncers add "$bouncer_name" -o raw)
  [[ -n "$api_key" && -f "$bouncer_config" ]] ||
    die "не удалось зарегистрировать CrowdSec firewall bouncer."

  python3 - "$bouncer_config" "$api_key" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
content = path.read_text()
updated, count = re.subn(
    r"(?m)^api_key\s*:\s*.*$",
    f"api_key: {sys.argv[2]}",
    content,
    count=1,
)
if count != 1:
    raise SystemExit("api_key not found in bouncer config")
path.write_text(updated)
PY

  chmod 600 "$bouncer_config"
  systemctl enable --now crowdsec-firewall-bouncer
  systemctl is-active --quiet crowdsec || die "CrowdSec не запустился."
  systemctl is-active --quiet crowdsec-firewall-bouncer ||
    die "CrowdSec firewall bouncer не запустился."
}

configure_unattended_upgrades() {
  apt_get install -y unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/52remnanode-unattended <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=${distro_id},codename=${distro_codename}";
    "origin=${distro_id},codename=${distro_codename}-security";
    "origin=${distro_id},codename=${distro_codename}-updates";
    "site=dl.cloudsmith.io";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
}

install_remnanode() {
  install -d -m 755 /opt/remnanode /var/log/remnanode

  cat > /opt/remnanode/.env <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
  chmod 600 /opt/remnanode/.env

  cat > /opt/remnanode/docker-compose.yml <<'EOF'
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
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: "${SECRET_KEY}"
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

  (
    cd /opt/remnanode
    docker compose config >/dev/null
    docker compose up -d --pull always
  )

  cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

  if [[ "$ENABLE_NODE_AUTOUPDATE" == "true" ]]; then
    cat > /etc/cron.d/remnanode-update <<'EOF'
0 11 * * 6 root cd /opt/remnanode && printf '\n=== %s ===\n' "$(date -Is)" >> /var/log/remnanode-update.log && docker compose up -d --pull always >> /var/log/remnanode-update.log 2>&1 && docker image prune -f >> /var/log/remnanode-update.log 2>&1
EOF
    chmod 644 /etc/cron.d/remnanode-update
    systemctl enable --now cron
  else
    rm -f /etc/cron.d/remnanode-update
  fi
}

collect_inputs() {
  while true; do
    read_required DOMAIN "Введите домен ноды для Selfsteal"
    DOMAIN=${DOMAIN,,}
    validate_domain "$DOMAIN" && break
    echo "Некорректное доменное имя."
    DOMAIN=""
  done

  read_required EMAIL "Введите email для ACME-уведомлений Caddy"
  [[ "$EMAIL" == *@*.* ]] || die "email выглядит некорректно."
  read_required SECRET_KEY "Введите Secret Key из панели Remnawave" true
  [[ "$SECRET_KEY" != *$'\n'* && "$SECRET_KEY" != *$'\r'* ]] ||
    die "Secret Key содержит недопустимый перевод строки."

  read_port NODE_PORT "На каком порту разместить API ноды?" 2222 1
  for reserved in 80 443 "$SELFSTEAL_PORT"; do
    [[ "$NODE_PORT" != "$reserved" ]] ||
      die "порт $NODE_PORT зарезервирован для Selfsteal/Reality."
  done

  CURRENT_SSH_PORT=$(
    sshd -T 2>/dev/null |
      awk '$1 == "port" && !found {port = $2; found = 1} END {print port}'
  )
  CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
  SSH_PORT=$CURRENT_SSH_PORT
  SSH_LOGIN_USER=${SUDO_USER:-root}

  if ask_yes_no "Установить и настроить CrowdSec?" "yes"; then
    INSTALL_CROWDSEC=true
  fi

  if ask_yes_no "Изменить текущий SSH-порт $CURRENT_SSH_PORT?" "no"; then
    CHANGE_SSH_PORT=true
    while true; do
      read_port SSH_PORT "Введите новый SSH-порт" 22222 1024
      if [[ "$SSH_PORT" == "$NODE_PORT" || "$SSH_PORT" == 80 || "$SSH_PORT" == 443 || "$SSH_PORT" == "$SELFSTEAL_PORT" ]]; then
        echo "Порт $SSH_PORT уже занят или зарезервирован."
        continue
      fi
      break
    done
    echo "Убедитесь, что TCP-порт $SSH_PORT разрешён во внешнем firewall провайдера."
  fi

  [[ "$NODE_PORT" != "$SSH_PORT" ]] ||
    die "NODE_PORT и SSH не могут использовать один порт $SSH_PORT."

  if ask_yes_no "Отключить вход по паролю и оставить только SSH-ключ?" "yes"; then
    ENABLE_KEY_ONLY=true
    find_public_key
    validate_public_key_file "$SSH_PUBLIC_KEY"
    select_ssh_user
  fi

  if ask_yes_no "Настроить UFW с доступом к NODE_PORT только от панели?" "yes"; then
    ENABLE_UFW=true
    read -r -p "Введите IP/CIDR панели Remnawave (пусто = открыть NODE_PORT всем): " PANEL_SOURCE </dev/tty
  fi

  if ask_yes_no "Включить автоматические security-обновления ОС и Caddy без автоперезагрузки?" "yes"; then
    ENABLE_UNATTENDED_UPGRADES=true
  fi

  if ask_yes_no "Обновлять контейнер Remnanode автоматически по субботам?" "yes"; then
    ENABLE_NODE_AUTOUPDATE=true
  fi

  echo
  echo "Проверьте параметры:"
  echo "  Домен Selfsteal: $DOMAIN"
  echo "  NODE_PORT: $NODE_PORT"
  echo "  SSH-порт: $SSH_PORT"
  echo "  Только SSH-ключ: $ENABLE_KEY_ONLY"
  echo "  CrowdSec: $INSTALL_CROWDSEC"
  echo "  UFW: $ENABLE_UFW"
  echo "  Автообновления ОС/Caddy: $ENABLE_UNATTENDED_UPGRADES"
  echo "  Автообновления Remnanode: $ENABLE_NODE_AUTOUPDATE"
  echo "  Заглушки: $SCRIPT_DIR/selfsteal-pages/*.html (случайный выбор один раз при установке)"
  ask_yes_no "Начать установку?" "yes" || exit 0
}

main() {
  clear
  echo "============================================================"
  echo " Remnanode + Selfsteal Caddy + BBR + optional CrowdSec"
  echo "============================================================"

  ensure_supported_os
  echo "Обнаружена поддерживаемая система: ${PRETTY_NAME:-unknown}"
  collect_inputs

  export DEBIAN_FRONTEND=noninteractive
  export UCFR_FORCE_CONFFOLD=1

  log "Обновление индекса пакетов и установка базовых компонентов"
  apt_get update
  apt_get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y \
    ca-certificates curl cron ethtool gnupg irqbalance nftables openssh-client openssh-server \
    python3
  systemctl enable --now irqbalance

  if [[ "$ENABLE_KEY_ONLY" == "true" ]]; then
    log "Установка публичного SSH-ключа"
    install_authorized_key
  fi

  log "Настройка SSH"
  configure_ssh

  log "Включение BBR и сетевой оптимизации"
  configure_bbr

  log "Установка Docker"
  install_docker

  log "Установка Caddy и Selfsteal-заглушки"
  install_caddy_selfsteal

  if [[ "$ENABLE_UFW" == "true" ]]; then
    log "Настройка UFW"
    configure_ufw
  fi

  if [[ "$INSTALL_CROWDSEC" == "true" ]]; then
    log "Установка CrowdSec"
    install_crowdsec
  else
    echo "CrowdSec пропущен по выбору пользователя."
  fi

  if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
    log "Настройка автоматических обновлений"
    configure_unattended_upgrades
  fi

  log "Установка Remnanode"
  install_remnanode

  echo
  echo "==================================================================="
  echo "Установка завершена."
  echo "Домен Selfsteal: $DOMAIN"
  echo "Локальный target Reality: 127.0.0.1:$SELFSTEAL_PORT"
  echo "serverNames: [\"$DOMAIN\"]"
  echo "SNI хоста: $DOMAIN"
  echo "Fingerprint: firefox"
  echo "xver: 0"
  echo "NODE_PORT: $NODE_PORT"
  echo "SSH-порт: $SSH_PORT"
  echo "CrowdSec: $INSTALL_CROWDSEC"
  echo "UFW: $ENABLE_UFW"
  echo "==================================================================="
  echo "Не закрывайте текущую SSH-сессию, пока не проверите новый вход."
  echo "Проверка Caddy:"
  echo "  curl --resolve $DOMAIN:$SELFSTEAL_PORT:127.0.0.1 https://$DOMAIN:$SELFSTEAL_PORT/"
  echo "Логи Caddy:"
  echo "  journalctl -u caddy -n 100 --no-pager"
  echo "Логи ноды:"
  echo "  docker compose -f /opt/remnanode/docker-compose.yml logs -f -t"
}

main "$@"