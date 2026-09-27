#!/usr/bin/env bash
set -Eeuo pipefail

# Интерактивный установщик HAProxy TCP relay для VLESS TCP/RAW REALITY.
# Поддерживаются Debian и Ubuntu. Запуск: sudo bash install-haproxy-vless.sh

readonly HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
readonly OPTIMIZER_URL="https://raw.githubusercontent.com/dexter-xray/node-installer/main/optimize-network.sh"
readonly NODE_INSTALLER_REPO="https://github.com/dexter-xray/node-installer.git"
readonly NODE_INSTALLER_DIR="/opt/node-installer"
readonly NODE_INSTALLER_SCRIPT="random-selfsteal/ult_crowdsec_selfsteal.sh"

declare -a BACKEND_IPS=()
declare -a BACKEND_PORTS=()

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

info() { printf "%b[INFO]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf "%b[OK]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf "%b[ERROR]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    printf "%b[ERROR]%b Ошибка в строке %s, код %s.\n" \
        "$C_RED" "$C_RESET" "${BASH_LINENO[0]:-?}" "$exit_code" >&2
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
}

check_os() {
    [[ -r /etc/os-release ]] || die "Не удалось определить операционную систему."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "Поддерживаются только Debian и Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}" ;;
    esac
}

wait_for_apt() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/cache/apt/archives/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
        (( waited >= 300 )) && die "APT занят более 5 минут. Повторите запуск позже."
        info "APT занят другим процессом; ожидание..."
        sleep 5
        (( waited += 5 ))
    done
}

apt_install() {
    wait_for_apt
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "$@"
}

valid_port() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ip() {
    local value=$1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
    else
        # Строгая проверка IPv4 без зависимости от Python.
        local IFS=. octets octet
        read -r -a octets <<< "$value"
        [[ ${#octets[@]} -eq 4 ]] || return 1
        for octet in "${octets[@]}"; do
            [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
            (( 10#$octet <= 255 )) || return 1
        done
    fi
}

ask_ip() {
    local value
    while true; do
        read -r -p "IP-адрес выходной зарубежной ноды: " value
        if valid_ip "$value"; then
            printf '%s' "$value"
            return 0
        fi
        warn "Введите корректный IPv4 или IPv6 адрес."
    done
}

ask_port() {
    local prompt=$1 value
    while true; do
        read -r -p "$prompt" value
        if valid_port "$value"; then
            printf '%s' "$value"
            return 0
        fi
        warn "Порт должен быть целым числом от 1 до 65535."
    done
}

ask_backend_count() {
    local value
    while true; do
        read -r -p "Количество выходных нод: " value
        if [[ $value =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 50 )); then
            REPLY=$((10#$value))
            return 0
        fi
        warn "Введите количество от 1 до 50."
    done
}

parse_backend_endpoint() {
    local endpoint=$1 ip port

    # IPv4: 203.0.113.10:443
    # IPv6: [2001:db8::10]:443
    if [[ $endpoint =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        ip=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
    elif [[ $endpoint =~ ^([^:]+):([0-9]+)$ ]]; then
        ip=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[2]}
    else
        return 1
    fi

    valid_ip "$ip" || return 1
    valid_port "$port" || return 1
    REPLY_IP=$ip
    REPLY_PORT=$port
}

ask_multiple_backends() {
    local expected=$1 input endpoint
    local -a entries=()

    while true; do
        read -r -p "Введите ${expected} нод через запятую (IP:порт,IP:порт): " input
        IFS=',' read -r -a entries <<< "$input"

        if (( ${#entries[@]} != expected )); then
            warn "Ожидалось нод: ${expected}; получено: ${#entries[@]}."
            continue
        fi

        BACKEND_IPS=()
        BACKEND_PORTS=()
        for endpoint in "${entries[@]}"; do
            # Удаляем пробелы вокруг и внутри элемента.
            endpoint=${endpoint//[[:space:]]/}
            if ! parse_backend_endpoint "$endpoint"; then
                warn "Некорректная нода: ${endpoint}. IPv4: 203.0.113.10:443; IPv6: [2001:db8::10]:443"
                BACKEND_IPS=()
                BACKEND_PORTS=()
                break
            fi
            BACKEND_IPS+=("$REPLY_IP")
            BACKEND_PORTS+=("$REPLY_PORT")
        done

        (( ${#BACKEND_IPS[@]} == expected )) && return 0
    done
}

format_haproxy_address() {
    local ip=$1 port=$2
    if [[ $ip == *:* ]]; then
        printf '[%s]:%s' "$ip" "$port"
    else
        printf '%s:%s' "$ip" "$port"
    fi
}

check_backend() {
    local ip=$1 port=$2
    info "Проверяю TCP-доступность ${ip}:${port}..."
    if timeout 8 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null; then
        ok "Выходная нода доступна по TCP."
    else
        warn "Сейчас не удалось подключиться к ${ip}:${port}."
        warn "Установка продолжится, но проверьте Xray, firewall и security group выходной ноды."
    fi
}

check_listen_port() {
    local port=$1 listeners
    listeners=$(ss -H -lntp "sport = :${port}" 2>/dev/null || true)
    if [[ -n $listeners ]] && ! grep -q 'haproxy' <<< "$listeners"; then
        printf '%s\n' "$listeners" >&2
        die "Входной порт ${port} уже занят другим процессом."
    fi
}

configure_haproxy() {
    local listen_port=$1
    local backend_address temp_cfg backup='' i
    local -a service_action=()
    temp_cfg=$(mktemp)

    cat > "$temp_cfg" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    user haproxy
    group haproxy
    daemon
    maxconn 20000

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 10s
    timeout client 24h
    timeout server 24h
    timeout tunnel 24h

frontend vless_reality_frontend
    bind 0.0.0.0:${listen_port}
    mode tcp
    default_backend vless_reality_backend

backend vless_reality_backend
    mode tcp
    balance roundrobin
    option tcp-check
EOF

    for i in "${!BACKEND_IPS[@]}"; do
        backend_address=$(format_haproxy_address "${BACKEND_IPS[$i]}" "${BACKEND_PORTS[$i]}")
        printf '    server foreign_xray_%d %s check inter 10s fall 3 rise 2\n' \
            "$((i + 1))" "$backend_address" >> "$temp_cfg"
    done

    haproxy -c -f "$temp_cfg"

    if [[ -f $HAPROXY_CFG ]]; then
        backup="${HAPROXY_CFG}.backup-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
        cp -a "$HAPROXY_CFG" "$backup"
        info "Резервная копия: ${backup}"
    fi

    install -o root -g root -m 0644 "$temp_cfg" "$HAPROXY_CFG"
    rm -f "$temp_cfg"

    if systemctl is-active --quiet haproxy; then
        service_action=(systemctl reload haproxy)
    else
        service_action=(systemctl enable --now haproxy)
    fi

    if ! "${service_action[@]}"; then
        if [[ -n $backup && -f $backup ]]; then
            warn "Восстанавливаю предыдущую конфигурацию HAProxy."
            cp -a "$backup" "$HAPROXY_CFG"
            systemctl reload haproxy 2>/dev/null || systemctl restart haproxy || true
        fi
        die "HAProxy не запустился. Проверьте: journalctl -u haproxy -n 100"
    fi

    systemctl is-active --quiet haproxy || die "Служба HAProxy не активна."
    ok "HAProxy настроен: 0.0.0.0:${listen_port} -> ${#BACKEND_IPS[@]} выходных нод."
}

load_haproxy_config() {
    local bind_address endpoint
    local -a endpoints=()

    [[ -f $HAPROXY_CFG ]] || die "Конфигурация ${HAPROXY_CFG} не найдена."

    bind_address=$(
        awk '
            $1 == "frontend" && $2 == "vless_reality_frontend" {inside=1; next}
            inside && $1 == "bind" {print $2; exit}
            inside && ($1 == "frontend" || $1 == "backend" || $1 == "listen") {exit}
        ' "$HAPROXY_CFG"
    )
    [[ -n $bind_address ]] ||
        die "Не найден frontend vless_reality_frontend в ${HAPROXY_CFG}."

    REPLY_LISTEN_PORT=${bind_address##*:}
    valid_port "$REPLY_LISTEN_PORT" ||
        die "Не удалось определить входной порт из строки bind: ${bind_address}"

    mapfile -t endpoints < <(
        awk '
            $1 == "backend" && $2 == "vless_reality_backend" {inside=1; next}
            inside && $1 == "server" {print $3}
            inside && ($1 == "frontend" || $1 == "backend" || $1 == "listen") {exit}
        ' "$HAPROXY_CFG"
    )

    (( ${#endpoints[@]} > 0 )) ||
        die "В backend vless_reality_backend не найдено выходных нод."

    BACKEND_IPS=()
    BACKEND_PORTS=()
    for endpoint in "${endpoints[@]}"; do
        parse_backend_endpoint "$endpoint" ||
            die "Не удалось разобрать адрес выходной ноды: ${endpoint}"
        BACKEND_IPS+=("$REPLY_IP")
        BACKEND_PORTS+=("$REPLY_PORT")
    done
}

show_haproxy_config() {
    local listen_port=$1 i address
    printf '\n%bТекущая конфигурация HAProxy%b\n' "$C_CYAN" "$C_RESET"
    printf '  Входной порт: %s\n' "$listen_port"
    printf '  Выходные ноды:\n'
    for i in "${!BACKEND_IPS[@]}"; do
        address=$(format_haproxy_address "${BACKEND_IPS[$i]}" "${BACKEND_PORTS[$i]}")
        printf '    %d) %s\n' "$((i + 1))" "$address"
    done
    printf '\n'
}

ask_backend_number() {
    local prompt=$1 value max=${#BACKEND_IPS[@]}
    while true; do
        read -r -p "$prompt [1-${max}]: " value
        if [[ $value =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= max )); then
            REPLY_INDEX=$((10#$value - 1))
            return 0
        fi
        warn "Введите номер от 1 до ${max}."
    done
}

ask_single_backend() {
    local endpoint
    while true; do
        read -r -p "Введите выходную ноду в формате IP:порт: " endpoint
        endpoint=${endpoint//[[:space:]]/}
        if parse_backend_endpoint "$endpoint"; then
            return 0
        fi
        warn "Неверный формат. IPv4: 203.0.113.10:443; IPv6: [2001:db8::10]:443"
    done
}

allow_backend_ufw() {
    local ip=$1 port=$2
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow out to "$ip" port "$port" proto tcp \
        comment 'HAProxy to foreign Xray' >/dev/null || true
    ufw status | grep -q '^Status: active' && ufw reload >/dev/null || true
}

allow_frontend_ufw() {
    local port=$1
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow "${port}/tcp" comment 'HAProxy VLESS REALITY' >/dev/null || true
    ufw status | grep -q '^Status: active' && ufw reload >/dev/null || true
}

reload_haproxy() {
    haproxy -c -f "$HAPROXY_CFG"
    if systemctl reload haproxy; then
        ok "HAProxy успешно перезагружен без разрыва активных соединений."
    else
        warn "Мягкая перезагрузка не удалась; выполняю restart."
        systemctl restart haproxy
        ok "HAProxy перезапущен."
    fi
}

manage_haproxy() {
    local listen_port choice i duplicate new_port

    check_os
    command -v haproxy >/dev/null 2>&1 ||
        die "HAProxy не установлен. Сначала выберите пункт 1."
    load_haproxy_config
    listen_port=$REPLY_LISTEN_PORT

    while true; do
        show_haproxy_config "$listen_port"
        cat <<'EOF'
  1) Добавить выходную ноду
  2) Удалить выходную ноду
  3) Изменить входной порт HAProxy
  4) Изменить порт выходной ноды
  5) Перезагрузить HAProxy
  0) Вернуться в главное меню
EOF
        read -r -p "Выберите действие [1/2/3/4/5/0]: " choice

        case "$choice" in
            1)
                ask_single_backend
                duplicate=0
                for i in "${!BACKEND_IPS[@]}"; do
                    if [[ ${BACKEND_IPS[$i]} == "$REPLY_IP" &&
                          ${BACKEND_PORTS[$i]} == "$REPLY_PORT" ]]; then
                        duplicate=1
                        break
                    fi
                done
                (( duplicate == 0 )) || { warn "Такая выходная нода уже существует."; continue; }
                BACKEND_IPS+=("$REPLY_IP")
                BACKEND_PORTS+=("$REPLY_PORT")
                check_backend "$REPLY_IP" "$REPLY_PORT"
                allow_backend_ufw "$REPLY_IP" "$REPLY_PORT"
                configure_haproxy "$listen_port"
                ;;
            2)
                if (( ${#BACKEND_IPS[@]} <= 1 )); then
                    warn "Нельзя удалить единственную выходную ноду."
                    continue
                fi
                ask_backend_number "Номер удаляемой ноды"
                unset "BACKEND_IPS[$REPLY_INDEX]"
                unset "BACKEND_PORTS[$REPLY_INDEX]"
                BACKEND_IPS=("${BACKEND_IPS[@]}")
                BACKEND_PORTS=("${BACKEND_PORTS[@]}")
                configure_haproxy "$listen_port"
                ;;
            3)
                new_port=$(ask_port "Новый входной TCP-порт HAProxy: ")
                if [[ $new_port == "$listen_port" ]]; then
                    warn "Этот порт уже используется HAProxy."
                    continue
                fi
                check_listen_port "$new_port"
                allow_frontend_ufw "$new_port"
                configure_haproxy "$new_port"
                warn "Старое правило UFW для порта ${listen_port} оставлено, чтобы не удалить чужое правило."
                listen_port=$new_port
                ;;
            4)
                ask_backend_number "Номер изменяемой ноды"
                new_port=$(ask_port "Новый порт для ${BACKEND_IPS[$REPLY_INDEX]}: ")
                BACKEND_PORTS[$REPLY_INDEX]=$new_port
                check_backend "${BACKEND_IPS[$REPLY_INDEX]}" "$new_port"
                allow_backend_ufw "${BACKEND_IPS[$REPLY_INDEX]}" "$new_port"
                configure_haproxy "$listen_port"
                ;;
            5)
                reload_haproxy
                ;;
            0)
                return 0
                ;;
            *)
                warn "Неизвестный пункт: ${choice}"
                ;;
        esac
    done
}

get_ssh_ports() {
    local ports=''
    if command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu || true)
    fi
    [[ -n $ports ]] || ports=22
    printf '%s\n' "$ports"
}

configure_ufw() {
    local listen_port=$1 ssh_port i
    info "Настраиваю UFW..."

    while read -r ssh_port; do
        [[ -n $ssh_port ]] || continue
        ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
        info "Разрешён SSH TCP-порт ${ssh_port}."
    done < <(get_ssh_ports)

    ufw allow "${listen_port}/tcp" comment 'HAProxy VLESS REALITY' >/dev/null
    for i in "${!BACKEND_IPS[@]}"; do
        ufw allow out to "${BACKEND_IPS[$i]}" port "${BACKEND_PORTS[$i]}" proto tcp \
            comment 'HAProxy to foreign Xray' >/dev/null || true
    done

    if ufw status | grep -q '^Status: active'; then
        ufw reload >/dev/null
    else
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
    fi

    ok "UFW включён; входящий TCP-порт ${listen_port} разрешён."
    ufw status verbose
}

run_network_optimizer() {
    local optimizer checksum
    optimizer=$(mktemp /tmp/optimize-network.XXXXXX.sh)

    info "Скачиваю сетевой оптимизатор из dexter-xray/node-installer..."
    curl --proto '=https' --tlsv1.2 -fsSL "$OPTIMIZER_URL" -o "$optimizer"
    chmod 0700 "$optimizer"
    checksum=$(sha256sum "$optimizer" | awk '{print $1}')
    info "SHA-256 загруженного optimize-network.sh: ${checksum}"

    # Перед запуском проверяем хотя бы базовые признаки корректного Bash-скрипта.
    head -n 1 "$optimizer" | grep -Eq '^#!.*(bash|env bash)' \
        || die "Загруженный оптимизатор не похож на Bash-скрипт."
    bash -n "$optimizer"
    bash "$optimizer"
    rm -f "$optimizer"
    ok "Сетевая оптимизация завершена."
}

run_haproxy_install() {
    local backend_count backend_ip backend_port listen_port i

    check_os
    apt_install ca-certificates curl haproxy iproute2 ufw

    ask_backend_count
    backend_count=$REPLY

    if (( backend_count == 1 )); then
        backend_ip=$(ask_ip)
        backend_port=$(ask_port "Порт VLESS REALITY на выходной ноде: ")
        BACKEND_IPS=("$backend_ip")
        BACKEND_PORTS=("$backend_port")
    else
        ask_multiple_backends "$backend_count"
        warn "Все выходные ноды должны принимать одну клиентскую конфигурацию REALITY."
    fi

    listen_port=$(ask_port "Входной TCP-порт HAProxy: ")

    printf '\nПараметры:\n'
    for i in "${!BACKEND_IPS[@]}"; do
        printf '  Выходная нода %d: %s\n' \
            "$((i + 1))" \
            "$(format_haproxy_address "${BACKEND_IPS[$i]}" "${BACKEND_PORTS[$i]}")"
    done
    printf '  HAProxy слушает: 0.0.0.0:%s\n\n' "$listen_port"

    check_listen_port "$listen_port"
    for i in "${!BACKEND_IPS[@]}"; do
        check_backend "${BACKEND_IPS[$i]}" "${BACKEND_PORTS[$i]}"
    done
    configure_haproxy "$listen_port"
    configure_ufw "$listen_port"
    run_network_optimizer

    printf '\n'
    ok "Установка завершена."
    printf '  Клиент VLESS: address = IP этого VPS, port = %s\n' "$listen_port"
    printf '  REALITY SNI, Public Key, Short ID и UUID не меняются.\n'
    printf '  Проверка: systemctl status haproxy --no-pager\n'
    printf '  Логи:     journalctl -u haproxy -f\n'
    printf '  Внимание: оптимизатор рекомендует перезагрузку: sudo reboot\n'
}

run_node_installer() {
    check_os
    apt_install ca-certificates git

    if [[ -d "${NODE_INSTALLER_DIR}/.git" ]]; then
        info "Репозиторий уже существует; обновляю fast-forward..."
        git -C "$NODE_INSTALLER_DIR" pull --ff-only
    elif [[ -e $NODE_INSTALLER_DIR ]]; then
        die "${NODE_INSTALLER_DIR} уже существует и не является Git-репозиторием."
    else
        git clone --depth 1 "$NODE_INSTALLER_REPO" "$NODE_INSTALLER_DIR"
    fi

    cd "${NODE_INSTALLER_DIR}/random-selfsteal"
    chmod +x "ult_crowdsec_selfsteal.sh"
    exec ./ult_crowdsec_selfsteal.sh
}

show_menu() {
    clear 2>/dev/null || true
    printf '%b' "$C_CYAN"
    cat <<'EOF'
============================================================
        Multi-script | Made by @IamLeonKennedy
============================================================
  1) Установить HAProxy TCP relay
  2) Установить ноду
  3) Управление HAProxy
  0) Отмена
============================================================
EOF
    printf '%b' "$C_RESET"
}

main() {
    local choice
    require_root
    while true; do
        show_menu
        read -r -p "Выберите вариант [1/2/3/0]: " choice

        case "$choice" in
            1) run_haproxy_install ;;
            2) run_node_installer ;;
            3) manage_haproxy ;;
            0) info "Отменено."; return 0 ;;
            *) warn "Неизвестный вариант: ${choice}" ;;
        esac
    done
}

main "$@"
