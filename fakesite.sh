#!/bin/bash

# Цвета для визуализации
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Без цвета

# Функция для отображения прогресса (только ASCII)
show_progress() {
    local current=$1
    local total=$2
    local status=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] ${GREEN}%3d%%${NC} ${YELLOW}%s${NC}" "$percent" "$status"
}

# Функция для отображения завершенного шага
show_complete() {
    local status=$1
    echo -e "\n${GREEN}[OK]${NC} ${status}"
}

# Функция для отображения ошибки
show_error() {
    local status=$1
    echo -e "\n${RED}[ERROR]${NC} ${status}"
}

# Функция для выполнения команд с подавлением вывода
execute_silent() {
    local cmd=$1
    local log_file="/tmp/sni_setup_$(date +%s).log"
    eval "$cmd" >> "$log_file" 2>&1
    return $?
}

# Очистка экрана и вывод заголовка
clear
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  Установка и настройка Self SNI Scripts by begugla  ${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# Общее количество шагов
TOTAL_STEPS=13
CURRENT_STEP=0

# Шаг 1: Проверка системы
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка операционной системы..."
sleep 0.3

if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    show_error "Система не поддерживается. Требуется Debian или Ubuntu."
    exit 1
fi
show_complete "Операционная система совместима"

# Шаг 2: Запрос доменного имени
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Ожидание ввода данных..."
echo ""
read -p "Введите доменное имя: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    show_error "Доменное имя не может быть пустым"
    exit 1
fi

read -p "Введите внутренний SNI Self порт (Enter для 9000): " SPORT
SPORT=${SPORT:-9000}
show_complete "Параметры получены"

# Шаг 3: Обновление системы
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Обновление списка пакетов..."
if execute_silent "apt update"; then
    show_complete "Список пакетов обновлен"
else
    show_error "Не удалось обновить список пакетов"
    exit 1
fi

# Шаг 4: Установка зависимостей
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Установка компонентов (nginx, certbot, git)..."
if execute_silent "DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx git curl dnsutils"; then
    show_complete "Компоненты успешно установлены"
else
    show_error "Не удалось установить необходимые компоненты"
    exit 1
fi

# Шаг 5: Получение внешнего IP
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Определение внешнего IP сервера..."
external_ip=$(curl -s --max-time 5 https://api.ipify.org)

if [[ -z "$external_ip" ]]; then
    show_error "Не удалось определить внешний IP сервера"
    exit 1
fi
show_complete "Внешний IP сервера: $external_ip"

# Шаг 6: Проверка DNS записи
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка A-записи домена..."
domain_ip=$(dig +short A "$DOMAIN" | head -n1)

if [[ -z "$domain_ip" ]]; then
    show_error "Не удалось получить A-запись для домена $DOMAIN"
    echo -e "${YELLOW}Подробнее: https://github.com/begugla0/selfsniscripts${NC}"
    exit 1
fi
show_complete "A-запись домена: $domain_ip"

# Шаг 7: Сравнение IP адресов
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка соответствия DNS записи..."
if [[ "$domain_ip" != "$external_ip" ]]; then
    show_error "A-запись домена не соответствует внешнему IP сервера"
    echo -e "${YELLOW}Подробнее: https://github.com/begugla0/selfsniscripts${NC}"
    exit 1
fi
show_complete "DNS записи корректны"

# Шаг 8: Остановка nginx (ПЕРЕД проверкой портов)
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Остановка nginx..."
systemctl stop nginx 2>/dev/null || true
show_complete "Nginx остановлен"

# Шаг 9: Проверка портов
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка портов 80 и 443..."

if ss -tuln | grep -q ":443 "; then
    show_error "Порт 443 занят"
    echo -e "${YELLOW}Подробнее: https://github.com/begugla0/selfsniscripts${NC}"
    exit 1
fi

if ss -tuln | grep -q ":80 "; then
    show_error "Порт 80 занят"
    echo -e "${YELLOW}Подробнее: https://github.com/begugla0/selfsniscripts${NC}"
    exit 1
fi
show_complete "Порты 80 и 443 свободны"

# Шаг 10: Загрузка шаблона сайта
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Загрузка шаблона веб-сайта..."
TEMP_DIR=$(mktemp -d)
if execute_silent "git clone --depth 1 https://github.com/learning-zone/website-templates.git $TEMP_DIR"; then
    SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)
    cp -r "$SITE_DIR"/* /var/www/html/ 2>/dev/null
    show_complete "Шаблон сайта установлен"
else
    show_error "Не удалось загрузить шаблон сайта"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Шаг 11: Получение SSL сертификата
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Получение SSL сертификата (может занять время)..."
if execute_silent "certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive"; then
    show_complete "SSL сертификат успешно получен"
else
    show_error "Не удалось получить SSL сертификат"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Шаг 12: Настройка Nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Создание конфигурации Nginx..."

cat > /etc/nginx/sites-enabled/sni.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }

    return 404;
}

server {
    listen 127.0.0.1:$SPORT ssl http2;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # Настройки Proxy Protocol
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
show_complete "Конфигурация Nginx создана"

# Шаг 13: Запуск Nginx
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Запуск Nginx..."

if nginx -t > /dev/null 2>&1 && systemctl start nginx > /dev/null 2>&1; then
    show_complete "Nginx успешно запущен"
else
    show_error "Ошибка при запуске Nginx"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Очистка временных файлов
rm -rf "$TEMP_DIR"

# Финальное сообщение
echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}          Установка завершена успешно!              ${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""
echo -e "${GREEN}Параметры для подключения:${NC}"
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo -e " ${YELLOW}Сертификат:${NC} /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo -e " ${YELLOW}Ключ:${NC}        /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo -e " ${YELLOW}Dest:${NC}        127.0.0.1:$SPORT"
echo -e " ${YELLOW}SNI:${NC}         $DOMAIN"
echo -e "${BLUE}-----------------------------------------------------${NC}"
echo ""
echo -e "${GREEN}Скрипт завершен!${NC}"
