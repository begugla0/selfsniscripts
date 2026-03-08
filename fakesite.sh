#!/bin/bash
set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ─── Константы ────────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="Self SNI Scripts"
GITHUB_URL="https://github.com/begugla0/selfsniscripts"
LOG_FILE="/var/log/sni_setup_$(date +%Y%m%d_%H%M%S).log"
NGINX_CONF_DIR="/etc/nginx/sites-enabled"
WEBROOT="/var/www/html"

TOTAL_STEPS=13
CURRENT_STEP=0

# ─── Вспомогательные функции ──────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

show_progress() {
    local current=$1 total=$2 status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    printf "\r${CYAN}[%s%s]${NC} ${GREEN}%3d%%${NC} ${YELLOW}%s${NC}" \
        "$(printf '%0.s=' $(seq 1 $filled) 2>/dev/null || printf '%*s' "$filled" '' | tr ' ' '=')" \
        "$(printf '%*s' "$empty" '')" \
        "$percent" "$status"
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
    log "STEP $CURRENT_STEP/$TOTAL_STEPS: $1"
}

ok() {
    echo -e "\n${GREEN}[OK]${NC} $1"
    log "OK: $1"
}

warn() {
    echo -e "\n${YELLOW}[WARN]${NC} $1"
    log "WARN: $1"
}

die() {
    echo -e "\n${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
    [[ -n "${2:-}" ]] && echo -e "${YELLOW}Подробнее: $2${NC}"
    echo -e "${YELLOW}Лог: $LOG_FILE${NC}"
    exit 1
}

run() {
    log "RUN: $*"
    eval "$*" >> "$LOG_FILE" 2>&1
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Скрипт должен быть запущен от root (sudo)"
}

# Ожидание освобождения dpkg/apt lock (до 60 сек)
wait_apt_lock() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock > /dev/null 2>&1; do
        if (( i++ > 60 )); then
            die "APT заблокирован другим процессом. Попробуйте позже."
        fi
        printf "\r${YELLOW}Ожидание освобождения APT lock... %ds${NC}" "$i"
        sleep 1
    done
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
    else
        die "Не удалось определить ОС (/etc/os-release не найден)"
    fi

    case "$OS_ID" in
        ubuntu|debian) ;;
        *)
            # Проверяем ID_LIKE для производных (Mint, Kali, Pop!_OS и т.д.)
            if [[ "$OS_LIKE" =~ (ubuntu|debian) ]]; then
                warn "Производная система ($OS_ID). Продолжаем как Debian-совместимую."
            else
                die "Система '$OS_ID' не поддерживается. Требуется Debian/Ubuntu или производные."
            fi
            ;;
    esac
    ok "ОС: $OS_ID $OS_VERSION"
}

check_port_free() {
    local port=$1
    if ss -tuln 2>/dev/null | grep -q ":${port} \|:${port}$"; then
        die "Порт $port занят. Освободите его перед установкой." "$GITHUB_URL"
    fi
}

get_external_ip() {
    local ip=""
    local providers=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )
    for url in "${providers[@]}"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

validate_domain() {
    local domain=$1
    # RFC-совместимая проверка формата
    if ! echo "$domain" | grep -qP '^(?=.{1,253}$)((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,}$' 2>/dev/null; then
        # Fallback без perl-regexp
        if ! echo "$domain" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
            die "Некорректный формат домена: $domain"
        fi
    fi
}

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        die "Некорректный порт: $port (допустимо 1–65535)"
    fi
    if (( port < 1024 )); then
        warn "Порт $port < 1024 — привилегированный. Убедитесь, что это намеренно."
    fi
}

setup_certbot_renewal() {
    if systemctl list-timers 2>/dev/null | grep -q "certbot.timer"; then
        systemctl enable --now certbot.timer 2>/dev/null || true
        if ! systemctl cat certbot.timer 2>/dev/null | grep -q "Persistent=true"; then
            mkdir -p /etc/systemd/system/certbot.timer.d/
            cat > /etc/systemd/system/certbot.timer.d/override.conf <<'EOF'
[Timer]
Persistent=true
EOF
            systemctl daemon-reload
            systemctl restart certbot.timer 2>/dev/null || true
        fi
        ok "Автопродление: systemd timer (Persistent=true)"
    elif [[ -f /etc/cron.d/certbot ]]; then
        ok "Автопродление: cron (уже настроен)"
    else
        cat > /etc/cron.d/certbot <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 */12 * * * root certbot -q renew --nginx
EOF
        ok "Автопродление: cron (создан)"
    fi
    run "certbot renew --dry-run" || warn "dry-run автопродления завершился с ошибкой (некритично)"
}

install_website_template() {
    local webroot=$1
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' RETURN

    if run "git clone --depth 1 https://github.com/learning-zone/website-templates.git $TEMP_DIR"; then
        local site_dir
        site_dir=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)
        rm -rf "${webroot:?}"/*
        cp -r "$site_dir"/. "$webroot/"
        ok "Шаблон сайта установлен из $(basename "$site_dir")"
    else
        warn "Не удалось загрузить шаблон. Будет использована страница nginx по умолчанию."
    fi
}

write_nginx_config() {
    local domain=$1 sport=$2 conf_path=$3

    cat > "$conf_path" <<EOF
# Сгенерировано $SCRIPT_NAME v$SCRIPT_VERSION — $(date)
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${sport} ssl;
    http2 on;

    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$domain/chain.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    ssl_stapling        on;
    ssl_stapling_verify on;
    resolver            1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout    5s;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    real_ip_header      proxy_protocol;
    set_real_ip_from    127.0.0.1;

    location / {
        root  $WEBROOT;
        index index.html index.htm;
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# ─── Точка входа ──────────────────────────────────────────────────────────────

# Инициализация лог-файла
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "=== $SCRIPT_NAME v$SCRIPT_VERSION started ==="

clear
echo -e "${CYAN}╔═════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   $SCRIPT_NAME v$SCRIPT_VERSION by begugla          ║${NC}"
echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 0. Root check ────────────────────────────────────────────────────────────
require_root

# ── 1. Проверка ОС ───────────────────────────────────────────────────────────
step "Проверка операционной системы..."
detect_os

# ── 2. Ввод параметров ───────────────────────────────────────────────────────
step "Ожидание ввода данных..."
echo ""

read -rp "  Введите доменное имя: " DOMAIN
[[ -z "$DOMAIN" ]] && die "Доменное имя не может быть пустым"
validate_domain "$DOMAIN"

read -rp "  Email для Let's Encrypt (Enter = admin@$DOMAIN): " LE_EMAIL
LE_EMAIL="${LE_EMAIL:-admin@$DOMAIN}"

read -rp "  Внутренний SNI порт (Enter = 9000): " SPORT
SPORT="${SPORT:-9000}"
validate_port "$SPORT"

ok "Параметры: домен=$DOMAIN  email=$LE_EMAIL  порт=$SPORT"

# ── 3. Обновление пакетов ─────────────────────────────────────────────────────
step "Обновление списка пакетов..."
wait_apt_lock
run "apt-get update -qq" || die "Не удалось обновить список пакетов"
ok "Список пакетов обновлён"

# ── 4. Установка зависимостей ────────────────────────────────────────────────
step "Установка зависимостей..."
PACKAGES=(nginx certbot python3-certbot-nginx git curl dnsutils)
run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${PACKAGES[*]}" \
    || die "Не удалось установить пакеты: ${PACKAGES[*]}"
ok "Установлено: ${PACKAGES[*]}"

# ── 5. Внешний IP ────────────────────────────────────────────────────────────
step "Определение внешнего IP..."
EXTERNAL_IP=$(get_external_ip) || die "Не удалось определить внешний IP сервера"
ok "Внешний IP: $EXTERNAL_IP"

# ── 6. DNS A-запись ──────────────────────────────────────────────────────────
step "Проверка A-записи домена $DOMAIN..."
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1)
[[ -z "$DOMAIN_IP" ]] && die "A-запись для $DOMAIN не найдена" "$GITHUB_URL"
ok "DNS A-запись: $DOMAIN_IP"

# ── 7. Сверка IP ─────────────────────────────────────────────────────────────
step "Проверка соответствия DNS ↔ IP сервера..."
if [[ "$DOMAIN_IP" != "$EXTERNAL_IP" ]]; then
    die "DNS ($DOMAIN_IP) ≠ IP сервера ($EXTERNAL_IP). Обновите A-запись." "$GITHUB_URL"
fi
ok "DNS корректен: $DOMAIN_IP = $EXTERNAL_IP"

# ── 8. Остановка nginx ───────────────────────────────────────────────────────
step "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
ok "Nginx остановлен"

# ── 9. Проверка портов ───────────────────────────────────────────────────────
step "Проверка доступности портов 80/443..."
check_port_free 80
check_port_free 443
ok "Порты 80 и 443 свободны"

# ── 10. Шаблон сайта ─────────────────────────────────────────────────────────
step "Загрузка шаблона сайта..."
install_website_template "$WEBROOT"

# ── 11. SSL сертификат ───────────────────────────────────────────────────────
step "Получение SSL сертификата (может занять время)..."
run "certbot certonly --standalone -d $DOMAIN --agree-tos -m $LE_EMAIL --non-interactive" \
    || die "Не удалось получить SSL сертификат. Проверьте DNS и порты." "$GITHUB_URL"
ok "SSL сертификат получен"
setup_certbot_renewal

# ── 12. Конфиг Nginx ─────────────────────────────────────────────────────────
step "Создание конфигурации Nginx..."
CONF_PATH="$NGINX_CONF_DIR/sni_${DOMAIN}.conf"
write_nginx_config "$DOMAIN" "$SPORT" "$CONF_PATH"
rm -f "$NGINX_CONF_DIR/default"
ok "Конфиг записан: $CONF_PATH"

# ── 13. Запуск Nginx ─────────────────────────────────────────────────────────
step "Запуск Nginx..."
nginx -t >> "$LOG_FILE" 2>&1 || die "Конфигурация Nginx содержит ошибки. Лог: $LOG_FILE"
systemctl enable --now nginx >> "$LOG_FILE" 2>&1 \
    || die "Не удалось запустить Nginx. Лог: $LOG_FILE"
ok "Nginx запущен и добавлен в автозагрузку"

# ─── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Установка завершена!                   ║${NC}"
echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Параметры подключения:${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e " ${YELLOW}SNI домен:${NC}   $DOMAIN"
echo -e " ${YELLOW}Dest:${NC}        127.0.0.1:$SPORT"
echo -e " ${YELLOW}Сертификат:${NC}  /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo -e " ${YELLOW}Ключ:${NC}        /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo -e " ${YELLOW}Лог установки:${NC} $LOG_FILE"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo ""
