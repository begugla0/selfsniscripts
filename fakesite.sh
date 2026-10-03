#!/usr/bin/env bash
# =====================================================================
#  Self SNI Scripts by begugla — v2
#  SNI-сайт (target/dest) для Xray Reality: Nginx + Let's Encrypt
#  https://github.com/begugla0/selfsniscripts
#
#  Запуск:
#    bash <(curl -Ls https://raw.githubusercontent.com/begugla0/selfsniscripts/main/fakesite.sh)
#
#  Справка по параметрам:  bash fakesite.sh --help
# =====================================================================

set -o pipefail
umask 022

SCRIPT_VERSION="2.0.0"
REPO_URL="https://github.com/begugla0/selfsniscripts"
SITES_ROOT="/var/www/selfsni"
ACME_ROOT="/var/www/selfsni-acme"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
BACKUP_DIR="/root/selfsni-backup"
LOG_FILE="/tmp/sni_setup_$(date +%Y%m%d_%H%M%S).log"
DEFAULT_PORT=9000

# Параметры (могут прийти из аргументов)
DOMAIN=""
SPORT=""
MODE=""
TEMPLATE=""
EMAIL=""
PROXY_PROTOCOL=0
ASSUME_YES=0
SKIP_DNS=0
ACTION="install"

# Служебное
TMP_DIRS=()
IPV4=""
IPV6=""
CURRENT_STEP=0
TOTAL_STEPS=12
SITE_INFO=""

# ---------------------------------------------------------------------
#  Оформление
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

# Выполнить команду, весь вывод — в лог. Аргументы передаются как есть (без eval).
run() {
    log "\$ $*"
    "$@" >>"$LOG_FILE" 2>&1
    local rc=$?
    ((rc != 0)) && log "(код возврата: $rc)"
    return $rc
}

show_progress() {
    local current=$1 total=$2 status=$3
    local percent=$((current * 100 / total))
    ((percent > 100)) && percent=100
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    local bar_f bar_e
    printf -v bar_f '%*s' "$filled" ''
    printf -v bar_e '%*s' "$empty" ''
    printf '\r%s[%s%s] %s%3d%%%s %s%s%s' "$CYAN" "${bar_f// /=}" "$bar_e" "$GREEN" "$percent" "$NC" "$YELLOW" "$status" "$NC"
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
    log "=== Шаг $CURRENT_STEP: $1"
}

ok()   { printf '\n%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; log "OK: $*"; }
warn() { printf '\n%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; log "WARN: $*"; }
note() { printf '     %s\n' "$*"; }
hint() { printf '     %s%s%s\n' "$YELLOW" "$*" "$NC"; }

show_log_tail() {
    [[ -s $LOG_FILE ]] || return 0
    printf '\n%sПоследние строки лога (%s):%s\n' "$BLUE" "$LOG_FILE" "$NC"
    tail -n 15 "$LOG_FILE" | sed 's/^/   /'
}

# die "сообщение" ["подсказка" ...]
die() {
    printf '\n%s[ERROR]%s %s\n' "$RED" "$NC" "$1"
    log "ERROR: $1"
    shift
    local h
    for h in "$@"; do hint "$h"; done
    printf '     %sПодробнее: %s%s\n' "$YELLOW" "$REPO_URL" "$NC"
    exit 1
}

# Ошибка выполнения команды — дополнительно показываем хвост лога
fail() {
    show_log_tail
    die "$@"
}

cleanup() {
    local d
    for d in "${TMP_DIRS[@]}"; do [[ -n $d && -d $d ]] && rm -rf "$d"; done
}
trap cleanup EXIT
trap 'printf "\n%sПрервано пользователем.%s\n" "$RED" "$NC"; exit 130' INT TERM

mktemp_dir() {
    local d
    d=$(mktemp -d /tmp/selfsni.XXXXXX) || die "Не удалось создать временную папку"
    TMP_DIRS+=("$d")
    printf '%s' "$d"
}

# ---------------------------------------------------------------------
#  Ввод (работает и при запуске через bash <(curl ...), и через curl | bash)
# ---------------------------------------------------------------------
has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask ПЕРЕМЕННАЯ "вопрос" "значение по умолчанию"
ask() {
    local __var=$1 __prompt=$2 __def=$3 __ans=""
    if ((ASSUME_YES)) || ! has_tty; then
        printf -v "$__var" '%s' "$__def"
        return 0
    fi
    read -r -p "$__prompt" __ans </dev/tty || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm "вопрос [y/N]: " n|y  → 0 если ответ «да»
confirm() {
    local ans def=${2:-n}
    if ((ASSUME_YES)) || ! has_tty; then
        [[ $def == y ]]
        return
    fi
    read -r -p "$1" ans </dev/tty || true
    ans=${ans:-$def}
    ans=${ans,,}
    [[ $ans == y* || $ans == д* ]]
}

# pickv ПЕРЕМЕННАЯ вариант1 вариант2 ... — случайный выбор без подоболочки
pickv() {
    local __var=$1
    shift
    local __arr=("$@")
    printf -v "$__var" '%s' "${__arr[RANDOM % ${#__arr[@]}]}"
}

# ---------------------------------------------------------------------
#  Справка и аргументы
# ---------------------------------------------------------------------
usage() {
    cat <<EOF
Self SNI Scripts v$SCRIPT_VERSION — SNI-сайт для Xray Reality (Nginx + Let's Encrypt)

Использование: bash fakesite.sh [параметры]

  -d, --domain DOMAIN    доменное имя (A-запись должна указывать на сервер)
  -p, --port PORT        внутренний порт nginx для Reality (по умолчанию $DEFAULT_PORT)
  -m, --mode MODE        reality — nginx на 127.0.0.1:PORT, на 443 работает Xray (по умолчанию)
                         direct  — nginx сам слушает 443 (обычный сайт, без Reality на 443)
  -t, --template T       random            уникальный сайт, случайная тематика (по умолчанию)
                         <тематика>        уникальный сайт выбранной тематики (см. --themes)
                         github            случайный готовый шаблон с GitHub
                         /путь/к/папке     свой сайт (в папке должен быть index.html)
                         keep              оставить текущий сайт
  -e, --email EMAIL      e-mail для Let's Encrypt (необязательно)
      --proxy-protocol   nginx принимает PROXY protocol от Xray (в Xray нужно xver: 1)
      --skip-dns-check   не сверять A/AAAA-записи с IP сервера (сервер за NAT и т.п.)
  -y, --yes              без вопросов, значения по умолчанию
      --check            диагностика: почему сайт не открывается
      --uninstall        удалить сайт и конфиг nginx (сертификат — по желанию)
      --themes           список тематик генератора
  -h, --help             эта справка

Примеры:
  bash fakesite.sh
  bash fakesite.sh -d de.example.com -p 9000 -t coffee -y
  bash fakesite.sh --check -d de.example.com
EOF
}

need_arg() { [[ -n ${2:-} && ${2:0:1} != "-" ]] || die "Параметру $1 нужно значение" "Справка: bash fakesite.sh --help"; }

parse_args() {
    while (($#)); do
        if [[ $1 == --*=* ]]; then
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
        fi
        case $1 in
            -d|--domain)      need_arg "$1" "${2:-}"; DOMAIN=$2; shift 2 ;;
            -p|--port)        need_arg "$1" "${2:-}"; SPORT=$2; shift 2 ;;
            -m|--mode)        need_arg "$1" "${2:-}"; MODE=$2; shift 2 ;;
            -t|--template)    need_arg "$1" "${2:-}"; TEMPLATE=$2; shift 2 ;;
            -e|--email)       need_arg "$1" "${2:-}"; EMAIL=$2; shift 2 ;;
            --proxy-protocol) PROXY_PROTOCOL=1; shift ;;
            --skip-dns-check) SKIP_DNS=1; shift ;;
            -y|--yes)         ASSUME_YES=1; shift ;;
            --check)          ACTION="check"; shift ;;
            --uninstall)      ACTION="uninstall"; shift ;;
            --themes)         ACTION="themes"; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) die "Неизвестный параметр: $1" "Справка: bash fakesite.sh --help" ;;
        esac
    done
}

# ---------------------------------------------------------------------
#  Проверки ввода
# ---------------------------------------------------------------------
normalize_domain() {
    local d=${1,,}
    d=${d//[[:space:]]/}
    d=${d#http://}
    d=${d#https://}
    d=${d%%/*}
    d=${d%%:*}
    d=${d%.}
    printf '%s' "$d"
}

valid_domain() {
    [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+(xn--[a-z0-9-]{1,59}|[a-z]{2,63})$ ]]
}

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) && [[ $1 != 80 && $1 != 443 ]]
}

valid_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# ---------------------------------------------------------------------
#  Система
# ---------------------------------------------------------------------
check_root() {
    ((EUID == 0)) || die "Скрипт нужно запускать от root" "Выполните: sudo -i, затем запустите скрипт снова"
}

check_os() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — не удалось определить систему"
    local info id like pretty
    info=$(. /etc/os-release && printf '%s|%s|%s' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-unknown}")
    IFS='|' read -r id like pretty <<<"$info"
    if [[ " $id $like " != *" debian "* && " $id $like " != *" ubuntu "* ]]; then
        die "Система не поддерживается: $pretty" "Нужен Debian 10+ или Ubuntu 20.04+ (и производные)"
    fi
    [[ -d /run/systemd/system ]] || die "Не найден systemd" "Скрипт рассчитан на обычный VPS с systemd (не контейнер без init)"
    SELFSNI_OS=$pretty
    log "ОС: $SELFSNI_OS"
}

nginx_version_ge() { # nginx_version_ge 1.25.1
    local v
    v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    [[ -n $v ]] || return 1
    [[ $(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n1) == "$1" ]]
}

has_ipv6_stack() { [[ -s /proc/net/if_inet6 ]]; }

# ---------------------------------------------------------------------
#  Сеть: IP, DNS, порты
# ---------------------------------------------------------------------
get_ipv4() {
    local u ip
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip; do
        ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

get_ipv6() {
    local u ip
    has_ipv6_stack || return 1
    for u in https://api6.ipify.org https://ipv6.icanhazip.com; do
        ip=$(curl -6 -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ $ip == *:* && $ip =~ ^[0-9a-fA-F:]+$ ]]; then
            printf '%s' "${ip,,}"
            return 0
        fi
    done
    return 1
}

# resolve A|AAAA домен → список IP (CNAME-цепочки отбрасываются)
resolve() {
    local type=$1 name=$2 out="" r
    for r in 1.1.1.1 8.8.8.8 ""; do
        out=$(dig +short +time=3 +tries=2 "$type" "$name" ${r:+"@$r"} 2>/dev/null)
        [[ -n $out ]] && break
    done
    if [[ $type == A ]]; then
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$out" | sort -u
    else
        grep -E '^[0-9a-fA-F:]+$' <<<"$out" | grep ':' | tr 'A-F' 'a-f' | sort -u
    fi
}

# Нормализация IPv6 для сравнения (раскрытие ::)
ipv6_full() {
    local ip=${1,,} left right fill n i out=""
    if [[ $ip == *::* ]]; then
        left=${ip%%::*}; right=${ip##*::}
        local lc=0 rc=0
        [[ -n $left ]] && lc=$(tr -cd ':' <<<"$left" | wc -c) && lc=$((lc + 1))
        [[ -n $right ]] && rc=$(tr -cd ':' <<<"$right" | wc -c) && rc=$((rc + 1))
        n=$((8 - lc - rc))
        fill=""
        for ((i = 0; i < n; i++)); do fill+="0:"; done
        ip="${left:+$left:}${fill}${right}"
        ip=${ip%:}
    fi
    local IFS=:
    for i in $ip; do out+=$(printf '%04x:' "0x${i:-0}"); done
    printf '%s' "${out%:}"
}

# Кто слушает TCP-порт (имена процессов через запятую), пусто — порт свободен
port_owner() {
    ss -Hltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | paste -sd, -
}
port_busy() { [[ -n $(ss -Hltn "sport = :$1" 2>/dev/null) ]]; }

# Какие конфиги nginx (кроме исключённых) слушают порт
nginx_files_listening() {
    local port=$1
    shift
    local f ex skip
    for f in "$NGINX_ENABLED"/* /etc/nginx/conf.d/*.conf; do
        [[ -e $f ]] || continue
        skip=0
        for ex in "$@"; do [[ $(readlink -f "$f") == "$(readlink -f "$ex")" ]] && skip=1; done
        ((skip)) && continue
        grep -qsE "^[[:space:]]*listen[[:space:]]+([0-9.]+:|\[[0-9a-fA-F:]*\]:)?$port([[:space:]]|;)" "$f" && printf '%s\n' "$f"
    done
}

check_dns() {
    if ((SKIP_DNS)); then
        warn "Проверка DNS пропущена (--skip-dns-check)"
        return 0
    fi

    step "Определение внешнего IP сервера..."
    IPV4=$(get_ipv4) || die "Не удалось определить внешний IPv4 сервера" \
        "Проверьте интернет на сервере: curl -4 https://api.ipify.org" \
        "Если сервер за NAT — запустите с --skip-dns-check"
    IPV6=$(get_ipv6) || IPV6=""
    ok "Внешний IP сервера: $IPV4${IPV6:+ / $IPV6}"

    step "Проверка DNS-записей домена..."
    local a_list aaaa_list
    a_list=$(resolve A "$DOMAIN")
    aaaa_list=$(resolve AAAA "$DOMAIN")

    if [[ -z $a_list ]]; then
        die "У домена $DOMAIN нет A-записи" \
            "Добавьте в DNS: тип A, имя $(dns_record_name), значение $IPV4" \
            "Обновление DNS занимает от 5 минут до нескольких часов: dig +short A $DOMAIN"
    fi

    if ! grep -qxF "$IPV4" <<<"$a_list"; then
        warn "A-запись $DOMAIN → $(paste -sd' ' <<<"$a_list"), а IP сервера — $IPV4"
        hint "Если включено проксирование Cloudflare (оранжевое облако) — выключите его (серое облако)."
        hint "Если только что меняли запись — подождите обновления DNS."
        confirm "     Продолжить всё равно? (сертификат, скорее всего, не выпустится) [y/N]: " n ||
            die "A-запись домена не соответствует IP сервера"
    elif (($(wc -l <<<"$a_list") > 1)); then
        warn "У домена несколько A-записей: $(paste -sd' ' <<<"$a_list")"
        hint "Let's Encrypt может проверить чужой IP. Оставьте только $IPV4."
    fi

    if [[ -n $aaaa_list ]]; then
        local match=0 a
        if [[ -n $IPV6 ]]; then
            while read -r a; do
                [[ $(ipv6_full "$a") == "$(ipv6_full "$IPV6")" ]] && match=1
            done <<<"$aaaa_list"
        fi
        if ((!match)); then
            warn "У домена есть AAAA-запись ($(paste -sd' ' <<<"$aaaa_list")), но она не ведёт на этот сервер"
            hint "Let's Encrypt предпочитает IPv6 — проверка, скорее всего, провалится."
            hint "Удалите AAAA-запись или укажите в ней IPv6 этого сервера."
            confirm "     Продолжить всё равно? [y/N]: " n || die "AAAA-запись домена не ведёт на этот сервер"
        fi
    fi
    ok "DNS настроен верно: $DOMAIN → $IPV4"
}

dns_record_name() {
    # example.com → «@», de.example.com → «de»
    if [[ $DOMAIN == *.*.* ]]; then printf '%s' "${DOMAIN%.*.*}"; else printf '@'; fi
}

check_ports() {
    step "Проверка портов..."
    local owner

    # 80 — нужен для выпуска/продления сертификата и редиректа на https
    if port_busy 80; then
        owner=$(port_owner 80)
        if [[ $owner != nginx* ]]; then
            die "Порт 80 занят: ${owner:-неизвестный процесс}" \
                "Порт 80 нужен для получения сертификата Let's Encrypt." \
                "Посмотреть: ss -ltnp 'sport = :80'" \
                "Apache: systemctl disable --now apache2"
        fi
    fi

    if [[ $MODE == direct ]]; then
        if port_busy 443; then
            owner=$(port_owner 443)
            if [[ $owner != nginx* ]]; then
                die "Порт 443 занят: ${owner:-неизвестный процесс}" \
                    "В режиме direct nginx сам слушает 443. Если на 443 работает Xray — используйте режим reality."
            fi
        fi
    else
        owner=$(port_owner 443)
        if [[ $owner == nginx* ]]; then
            warn "Порт 443 сейчас занят nginx — Xray не сможет его занять"
            hint "Проверьте другие сайты nginx: grep -rn 'listen.*443' /etc/nginx/"
        fi
    fi

    # Внутренний порт для Reality
    if [[ $MODE == reality ]] && port_busy "$SPORT"; then
        owner=$(port_owner "$SPORT")
        if [[ $owner != nginx* ]]; then
            die "Порт $SPORT занят: ${owner:-неизвестный процесс}" "Укажите другой порт, например: -p 9443"
        fi
    fi

    # Не занят ли нужный порт другим сайтом nginx
    local p conflicts
    if [[ $MODE == reality ]]; then p=$SPORT; else p=443; fi
    conflicts=$(nginx_files_listening "$p" "$NGINX_CONF_LINK" "${OLD_CONFIGS[@]}")
    if [[ -n $conflicts ]]; then
        if [[ $MODE == reality ]]; then
            die "Порт $p уже использует другой сайт nginx: $(paste -sd' ' <<<"$conflicts")" "Укажите другой порт: -p 9443"
        else
            warn "Порт 443 уже слушает другой сайт nginx: $(paste -sd' ' <<<"$conflicts")"
        fi
    fi
    ok "Порты в порядке (80$([[ $MODE == direct ]] && echo ', 443' || echo ", 127.0.0.1:$SPORT"))"
}

check_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        local p opened=()
        for p in 80 443; do
            if ! ufw status 2>/dev/null | grep -qE "^$p(/tcp)?[[:space:]]+ALLOW"; then
                run ufw allow "$p/tcp" && opened+=("$p")
            fi
        done
        ((${#opened[@]})) && ok "UFW: открыты порты ${opened[*]}/tcp"
    fi
}

# ---------------------------------------------------------------------
#  Пакеты
# ---------------------------------------------------------------------
install_packages() {
    local pkgs=(nginx certbot curl dnsutils openssl ca-certificates)
    [[ $TEMPLATE == github ]] && pkgs+=(git)
    local missing=() p
    for p in "${pkgs[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
    done
    # dig может прийти из bind9-dnsutils
    if [[ " ${missing[*]} " == *" dnsutils "* ]] && command -v dig >/dev/null 2>&1; then
        missing=("${missing[@]/dnsutils/}")
    fi
    local real=()
    for p in "${missing[@]}"; do [[ -n $p ]] && real+=("$p"); done

    step "Установка компонентов (nginx, certbot)..."
    if ((${#real[@]} == 0)); then
        ok "Все компоненты уже установлены"
        return 0
    fi
    local apt_opts=(-o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold -q)
    run env DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" update ||
        fail "Не удалось обновить список пакетов" "Проверьте /etc/apt/sources.list и интернет на сервере"
    run env DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y "${real[@]}" ||
        fail "Не удалось установить: ${real[*]}" "Если занят dpkg — дождитесь окончания автообновлений и запустите снова"
    ok "Установлено: ${real[*]}"
}

# =====================================================================
#  Генератор уникальных сайтов
#  Тематика × макет × палитра × шрифты × рисунок — каждый запуск даёт
#  новый сайт, которого нет в публичных коллекциях шаблонов.
# =====================================================================
THEMES=(coffee architecture law dental photo software bakery logistics accounting yoga interior bikes florist renovation translation)

declare -A THEME_RU=(
    [coffee]="Обжарка кофе / кофейня"     [architecture]="Архитектурное бюро"
    [law]="Юридическая фирма"             [dental]="Стоматология"
    [photo]="Фотостудия"                  [software]="Разработка ПО"
    [bakery]="Пекарня"                    [logistics]="Логистика и грузоперевозки"
    [accounting]="Бухгалтерия и налоги"   [yoga]="Студия йоги"
    [interior]="Дизайн интерьеров"        [bikes]="Веломастерская"
    [florist]="Цветочная мастерская"      [renovation]="Ремонт и строительство"
    [translation]="Бюро переводов"
)

theme_coffee() {
    T_NAMES=("%s Coffee Roasters" "%s Roastery" "%s Coffee")
    T_FALLBACK=("Northside" "Copper Kettle" "Harbour Street" "Field Notes")
    T_LABEL="Coffee"
    T_TAGLINES=("Small-batch coffee, roasted twice a week" "Seasonal coffee from farms we know by name")
    T_HERO=("Coffee roasted in small batches, twice a week" "Seasonal beans, roasted close to home" "We roast on Tuesdays and Fridays")
    T_LEAD=("We buy green coffee directly from a handful of farms in Ethiopia, Colombia and Guatemala and roast it in 12 kg batches. Order beans online or drop by the roastery for a cup."
            "Every bag carries the roast date and the name of the farm. We roast to order, so your coffee leaves the building no more than two days after it comes out of the drum.")
    T_ABOUT_H=("How we started" "About the roastery")
    T_ABOUT=("We started roasting in a rented garage in @YEAR@ with a second-hand 5 kg drum roaster and a list of three cafes willing to try our beans."
             "Today we supply cafes and offices across the city, but the routine has not changed: every batch is cupped before it is packed, and anything that does not taste right goes into the staff jar.")
    T_SERVICES=("Bean subscription|Two bags every two or four weeks, roasted to order and shipped the next morning.|from 18 EUR"
                "Office coffee|Beans, grinders and machine servicing for teams of 10 to 200 people.|on request"
                "Wholesale for cafes|Espresso and filter coffee, barista training and a fixed delivery day.|on request"
                "Cupping sessions|An hour at the roastery tasting six coffees side by side with our head roaster.|25 EUR"
                "Home brewing class|Pour-over, AeroPress and French press, using the equipment you already own.|35 EUR"
                "Gift boxes|Three 250 g bags with tasting notes, wrapped and sent with your message.|39 EUR")
    T_STEPS=("Pick a coffee|Choose single origins or let us rotate the seasonal lots for you."
             "We roast to order|Your beans are roasted on the next roast day and rested overnight."
             "Delivered fresh|Bags ship the following morning with the roast date printed on the label.")
    T_QUOTES=("The Ethiopian natural from last spring is still the best coffee I have made at home.|Marta K."
              "Switching the office to their beans ended the daily complaints about the kitchen machine.|Daniel R., office manager")
    T_HOURS=("Monday – Friday|8:00 – 18:00" "Saturday|9:00 – 15:00" "Sunday|Closed")
    T_CTA="Order beans"; T_CTA2="Visit the roastery"
    T_PALETTES=("#fbf8f3 #efe6da #24170f #6d5a4c #1f5b4a #ffffff #c9a227"
                "#1d1714 #2a221d #f2e8de #b9a898 #e3a857 #1d1714 #7aa58c"
                "#ffffff #f1eeea #1b1b1b #5e5a56 #8c2f1c #ffffff #e5c07b")
    T_FONTS=("slab;humanist" "oldstyle;oldstyle" "geometric;system")
    T_MOTIFS=(circles waves rings)
}

theme_architecture() {
    T_NAMES=("Studio %s" "%s Architects" "%s Architecture")
    T_FALLBACK=("Lindqvist" "Moraine" "Halden" "Ostrava")
    T_LABEL="Projects"
    T_TAGLINES=("Architecture for homes, schools and small workplaces" "Buildings designed around the people who use them")
    T_HERO=("Calm buildings that age well" "We design houses, schools and small workplaces" "Architecture that starts with how you live")
    T_LEAD=("A practice of eight architects working on residential, educational and small commercial projects. We take each project from the first sketch to the final site visit."
            "We work with timber, brick and concrete, and we prefer to keep what can be kept. Most of our projects are renovations and extensions of existing buildings.")
    T_ABOUT_H=("About the studio" "The practice")
    T_ABOUT=("The studio was founded in @YEAR@ by two architects who met while restoring a pre-war school building. Restoration is still a large part of what we do."
             "We keep the team small on purpose: the architect who draws your first sketch is the one who walks the site with the builder.")
    T_SERVICES=("Residential design|New houses and apartments, from planning permission to construction drawings.|fixed fee"
                "Extensions and renovations|Lofts, rear extensions and full refurbishments of existing homes.|from 2 500 EUR"
                "Feasibility studies|What can be built on a plot, at what cost and within which rules.|from 900 EUR"
                "Interior architecture|Layouts, joinery and lighting plans for homes and offices.|on request"
                "Planning applications|Drawings, reports and liaison with the local planning office.|from 1 200 EUR"
                "Site supervision|Regular site visits and quality checks during construction.|monthly fee")
    T_STEPS=("First meeting|We visit the site and talk through your brief, budget and timing."
             "Design|Sketches, models and drawings, refined with you over several rounds."
             "Construction|We prepare tender documents and stay on site until handover.")
    T_QUOTES=("They found a way to bring daylight into the middle of a very deep terraced house.|Anna and Piotr, homeowners"
              "Clear drawings, realistic budgets and no surprises on site.|Building contractor")
    T_HOURS=("Monday – Friday|9:00 – 18:00" "Saturday – Sunday|By appointment")
    T_CTA="Discuss a project"; T_CTA2="See our approach"
    T_PALETTES=("#ffffff #eef0f2 #111418 #5a636e #1f3fbf #ffffff #f2c94c"
                "#e9e7e2 #dcd8d0 #1e1e1c #5f5c55 #1e1e1c #e9e7e2 #b5652b"
                "#14171a #1f2428 #e9ecef #9aa4ad #f0b429 #14171a #4f86c6")
    T_FONTS=("grotesk;grotesk" "didone;grotesk" "geometric;geometric")
    T_MOTIFS=(arches blocks grid)
}

theme_law() {
    T_NAMES=("%s & Partners" "%s Legal" "Law Office %s")
    T_FALLBACK=("Weber Lang" "Novak" "Albright" "Kessler")
    T_LABEL="Practice areas"
    T_TAGLINES=("Practical legal advice for companies and private clients" "Commercial, employment and property law")
    T_HERO=("Clear legal advice, without the jargon" "Legal support for businesses and families" "Contracts, disputes and property, handled carefully")
    T_LEAD=("We advise small and medium-sized companies, founders and private clients. Every matter is led by a partner, and you always know who is working on your case and what it costs."
            "Our lawyers work in English, German and Polish. Most questions can be answered in a first one-hour consultation, after which we give you a written fee estimate.")
    T_ABOUT_H=("About the firm" "Who we are")
    T_ABOUT=("The firm was established in @YEAR@ and today has six lawyers and two paralegals. We are members of the local bar association and carry full professional indemnity insurance."
             "We prefer to solve problems before they reach a courtroom, but when litigation is the right answer we prepare for it thoroughly.")
    T_SERVICES=("Commercial contracts|Drafting and reviewing supply, service, licensing and distribution agreements.|from 300 EUR"
                "Employment law|Contracts, internal policies, dismissals and representation before labour courts.|hourly"
                "Real estate|Purchases, leases and due diligence for residential and commercial property.|fixed fee"
                "Company formation|Setting up companies, shareholder agreements and corporate housekeeping.|from 650 EUR"
                "Debt recovery|Pre-court demands, payment orders and enforcement proceedings.|success fee"
                "Family law and mediation|Divorce, custody arrangements and mediated settlements.|hourly")
    T_STEPS=("Consultation|A one-hour meeting, in person or by video, to understand your situation."
             "Written estimate|We confirm the scope of work and a fee estimate in writing."
             "Representation|A named partner leads your matter and reports to you regularly.")
    T_QUOTES=("They explained our options in plain language and the dispute was settled within two months.|Managing director, manufacturing company"
              "Fast, precise work on our shareholder agreement before the investment round.|Startup founder")
    T_HOURS=("Monday – Thursday|8:30 – 17:30" "Friday|8:30 – 15:00" "Weekends|Closed")
    T_CTA="Book a consultation"; T_CTA2="Our practice areas"
    T_PALETTES=("#fcfcfa #eef0f3 #14213d #4f5b6e #14213d #ffffff #b08d57"
                "#f7f4ef #ebe5da #2b1b1b #6b5b55 #7a1f2b #ffffff #c2a36b"
                "#0f1a2b #17263d #eef1f6 #a7b2c3 #d4b26a #0f1a2b #6f8fbf")
    T_FONTS=("oldstyle;transitional" "didone;transitional" "transitional;humanist")
    T_MOTIFS=(grid stripes blocks)
}

theme_dental() {
    T_NAMES=("%s Dental" "%s Dental Clinic" "Dentistry %s")
    T_FALLBACK=("Bright Street" "Parkside" "Lakeview" "Old Town")
    T_LABEL="Treatments"
    T_TAGLINES=("General and cosmetic dentistry for adults and children" "Unhurried dental care in the city centre")
    T_HERO=("Dental care that takes its time" "A dental clinic for the whole family" "Check-ups, implants and aligners under one roof")
    T_LEAD=("Appointments start at 45 minutes, so there is time to explain every step. We see adults and children, and we keep a few slots free each day for emergencies."
            "Four dentists, two hygienists and a modern X-ray suite in one clinic. We give you a written treatment plan with prices before any work begins.")
    T_ABOUT_H=("About the clinic" "Our team")
    T_ABOUT=("The clinic opened in @YEAR@ in a renovated ground floor near the old town. Since then we have grown to four treatment rooms and a small team that rarely changes."
             "Many of our patients are nervous about dentists. We explain what we are doing before we do it, and you can stop the treatment at any moment.")
    T_SERVICES=("Check-up and hygiene|Examination, scaling and polishing, with advice on home care.|60 EUR"
                "Fillings|Tooth-coloured composite fillings, usually completed in one visit.|from 80 EUR"
                "Clear aligners|Invisible orthodontic treatment with a digital scan and progress checks.|from 2 900 EUR"
                "Implants|Single-tooth and multi-tooth implants, planned on a 3D scan.|on consultation"
                "Whitening|In-clinic whitening or custom trays for use at home.|250 EUR"
                "Children's dentistry|Gentle first visits, sealants and fluoride for children from age three.|from 40 EUR")
    T_STEPS=("Book online or call|Choose a time that suits you; emergency slots are kept free daily."
             "Examination|A full check-up, X-rays if needed and a conversation about your options."
             "Treatment plan|A written plan with prices, so you can decide without pressure.")
    T_QUOTES=("The first dentist in years who made me feel calm in the chair.|Katarzyna W."
              "Our children actually look forward to their check-ups here.|Tomasz, father of two")
    T_HOURS=("Monday – Friday|8:00 – 20:00" "Saturday|9:00 – 14:00" "Sunday|Closed")
    T_CTA="Book an appointment"; T_CTA2="See treatments"
    T_PALETTES=("#ffffff #eef7f6 #12302d #4d6966 #0f7c72 #ffffff #8fd3c8"
                "#f6f9fc #e6eef7 #10243e #50627a #2463d1 #ffffff #9ec5ff"
                "#fffdfb #f3efe9 #262626 #66615b #2f6f5e #ffffff #e9b9a0")
    T_FONTS=("humanist;humanist" "geometric;system" "classical;system")
    T_MOTIFS=(circles waves rings)
}

theme_photo() {
    T_NAMES=("%s Studio" "%s Photography" "Studio %s")
    T_FALLBACK=("Silver Hour" "North Light" "Grain" "Aperture Lane")
    T_LABEL="Sessions"
    T_TAGLINES=("Portrait, product and event photography" "A daylight studio for portraits and products")
    T_HERO=("Photographs people keep for a long time" "Portraits and product photography in natural light" "A daylight studio in the middle of the city")
    T_LEAD=("Our studio has six metres of north-facing windows, so most portraits are made in daylight. We also shoot products, interiors and small events on location."
            "Two photographers, one retoucher and a studio that can be rented by the hour. You receive edited images within five working days.")
    T_ABOUT_H=("About the studio" "Behind the camera")
    T_ABOUT=("We opened the studio in @YEAR@ in a former print workshop. The big windows and the concrete floor stayed; the ink did not."
             "We like simple pictures: good light, an honest expression and as little retouching as possible.")
    T_SERVICES=("Portrait sessions|One hour in the studio, ten retouched images and a private online gallery.|from 180 EUR"
                "Product photography|Packshots and styled images for online shops and catalogues.|from 25 EUR per item"
                "Corporate headshots|Consistent portraits for teams, in our studio or at your office.|from 60 EUR per person"
                "Weddings and events|Documentary coverage of ceremonies, parties and conferences.|on request"
                "Studio rental|Daylight studio with backdrops and lighting, rented by the hour.|35 EUR per hour"
                "Retouching|Colour correction and careful retouching of your own images.|from 8 EUR per image")
    T_STEPS=("Plan the shoot|We agree on the style, location and list of images in a short call."
             "Shooting day|A relaxed session in the studio or on location."
             "Delivery|Edited images in a private online gallery within five working days.")
    T_QUOTES=("The product photos doubled the time visitors spent on our shop pages.|Online ceramics shop"
              "I hate being photographed and I love these portraits.|Ewa M.")
    T_HOURS=("Tuesday – Friday|10:00 – 19:00" "Saturday|10:00 – 16:00" "Sunday – Monday|By appointment")
    T_CTA="Book a session"; T_CTA2="Studio rental"
    T_PALETTES=("#0e0e0e #1a1a1a #f4f4f2 #a3a3a0 #f4f4f2 #0e0e0e #d64545"
                "#ffffff #f0f0f0 #111111 #6b6b6b #111111 #ffffff #e0a100"
                "#191612 #26211b #efe7da #b8ab98 #d9a441 #191612 #8c6b4f")
    T_FONTS=("didone;grotesk" "geometric;grotesk" "grotesk;system")
    T_MOTIFS=(rings circles blocks)
}

theme_software() {
    T_NAMES=("%s Labs" "%s Software" "%s Systems")
    T_FALLBACK=("Bitfield" "Northwind" "Corvid" "Tessellate")
    T_LABEL="Services"
    T_TAGLINES=("Web and mobile software for growing companies" "We build and maintain business software")
    T_HERO=("Software that keeps working after launch" "We build web applications and keep them running" "Engineering for companies without an engineering team")
    T_LEAD=("A team of twelve engineers and designers building web applications, internal tools and integrations. We stay on after launch to maintain and improve what we build."
            "We take over projects at any stage: from a first prototype to an ageing system that needs to be stabilised, documented and moved to modern infrastructure.")
    T_ABOUT_H=("About us" "How we work")
    T_ABOUT=("We have been building software since @YEAR@. Most of our clients have worked with us for more than three years, and several started with a single small integration."
             "Every project has a lead engineer who talks to you directly. We write documentation as we go, so you are never locked in to us.")
    T_SERVICES=("Web applications|Customer portals, booking systems and internal tools built with proven frameworks.|from 15 000 EUR"
                "Mobile apps|iOS and Android apps sharing one codebase, published under your account.|from 20 000 EUR"
                "APIs and integrations|Connecting your CRM, accounting, warehouse and payment systems.|from 3 000 EUR"
                "Cloud infrastructure|Migration, monitoring and cost reviews for AWS, Azure and Hetzner.|monthly"
                "Code audits|An independent review of security, architecture and maintainability.|from 2 500 EUR"
                "Support and maintenance|Updates, bug fixes and on-call support with agreed response times.|monthly")
    T_STEPS=("Discovery|Two weeks to map requirements, risks and a realistic budget."
             "Build|Working software every two weeks, deployed to a test environment you can use."
             "Run|Monitoring, updates and improvements once the system is live.")
    T_QUOTES=("They took over a system nobody understood and made it boring again, in the best sense.|CTO, logistics company"
              "Clear estimates, weekly demos and code we actually own.|Operations director, retail chain")
    T_HOURS=("Monday – Friday|9:00 – 18:00 CET" "Support|24/7 for maintenance clients")
    T_CTA="Start a project"; T_CTA2="Our services"
    T_PALETTES=("#ffffff #f2f4f8 #0d1321 #56607a #3b4cca #ffffff #18c29c"
                "#0b1020 #141b2f #e6e9f2 #9aa3bd #8b98ff #0b1020 #2fd3a6"
                "#f5f5f0 #e8e8df #1c1c1c #5f5f58 #c2410c #ffffff #2f6fdc")
    T_FONTS=("grotesk;system" "mono;system" "geometric;system")
    T_MOTIFS=(grid blocks stripes)
}

theme_bakery() {
    T_NAMES=("%s Bakery" "%s Bread and Pastry" "Bakehouse %s")
    T_FALLBACK=("Rye and Barley" "Mill Lane" "Morning Crumb" "Old Oven")
    T_LABEL="Menu"
    T_TAGLINES=("Sourdough bread and pastry, baked every morning" "A neighbourhood bakery since @YEAR@")
    T_HERO=("Bread baked before sunrise" "Sourdough, rye and pastry, baked every morning" "Our ovens are on at four")
    T_LEAD=("We bake with stone-milled flour, long fermentation and no shortcuts. The first loaves come out of the oven at six, and we usually sell out of croissants by eleven."
            "A small bakery with a big oven: sourdough, rye bread, pastries and cakes made from scratch every day by a team of five bakers.")
    T_ABOUT_H=("Our story" "About the bakery")
    T_ABOUT=("The bakery opened in @YEAR@ with one oven and a single sourdough starter that is still in use today."
             "We buy flour from two regional mills and butter from a dairy an hour away. Whatever is left at closing time goes to a local food bank.")
    T_SERVICES=("Country sourdough|Wheat and spelt, 36-hour fermentation, crisp dark crust.|5.50 EUR"
                "Butter croissants|Laminated over three days with cultured butter.|2.80 EUR"
                "Cardamom buns|Soft dough, cardamom sugar, baked fresh every hour.|3.20 EUR"
                "Dark rye|Whole rye with sunflower seeds, keeps for a week.|4.90 EUR"
                "Celebration cakes|Made to order with two days' notice.|from 45 EUR"
                "Wholesale bread|Daily deliveries for cafes and restaurants nearby.|on request")
    T_STEPS=("Order by 14:00|Tell us what you need for the next day by phone or email."
             "We bake overnight|Your order is baked in the early morning batch."
             "Pick up or delivery|Collect from 7:00 or receive it with our morning van.")
    T_QUOTES=("The rye bread alone is worth the walk across town.|Regular customer"
              "Our cafe switched to their sourdough and customers noticed the same week.|Cafe owner")
    T_HOURS=("Monday – Friday|7:00 – 19:00" "Saturday|7:00 – 15:00" "Sunday|8:00 – 13:00")
    T_CTA="Order for tomorrow"; T_CTA2="See the menu"
    T_PALETTES=("#fffaf0 #f6ead0 #3a2414 #7a604b #7b3f1d #ffffff #f2b134"
                "#fdf3f4 #f7dfe3 #3b1f2b #7b5b66 #a3284f #ffffff #f3c06b"
                "#f4efe4 #e7dcc6 #1f2a1f #5d6656 #355e3b #ffffff #e0a43a")
    T_FONTS=("oldstyle;humanist" "slab;transitional" "didone;oldstyle")
    T_MOTIFS=(petals circles waves)
}

theme_logistics() {
    T_NAMES=("%s Logistics" "%s Freight" "%s Cargo")
    T_FALLBACK=("Eastline" "Baltic Route" "Transcar" "Meridian")
    T_LABEL="Services"
    T_TAGLINES=("Road freight and warehousing across Europe" "Freight forwarding between Central and Western Europe")
    T_HERO=("Freight that arrives when we said it would" "Road freight across Europe, tracked door to door" "Full loads, part loads and warehousing")
    T_LEAD=("We move full and part loads between Poland, Germany, the Benelux and Scandinavia with our own fleet of 40 trucks and a network of trusted carriers."
            "One dispatcher looks after your account and answers the phone. Every shipment is GPS-tracked and you receive delivery confirmation with signed documents the same day.")
    T_ABOUT_H=("About the company" "Who we are")
    T_ABOUT=("The company was founded in @YEAR@ with three trucks and a single regular customer. Today we run a fleet of 40 vehicles and a 6 000 m² warehouse."
             "Our drivers are employed by us, not subcontracted, and our trucks are replaced every five years.")
    T_SERVICES=("Full truck loads|Dedicated 13.6 m trailers for direct deliveries across Europe.|per route"
                "Part loads|Groupage shipments on fixed weekly lines between major cities.|per pallet"
                "Warehousing|Storage, cross-docking and order picking in our bonded warehouse.|monthly"
                "Customs clearance|Import and export declarations handled by our own agents.|from 45 EUR"
                "Temperature control|Refrigerated transport for food and pharmaceuticals.|per route"
                "Last-mile delivery|Same-day and next-day delivery to shops and building sites.|on request")
    T_STEPS=("Request a quote|Send the route, dates and cargo details; we reply within two hours."
             "Collection|The truck arrives at the agreed time with the documents prepared."
             "Delivery|Live tracking and signed delivery documents on the same day.")
    T_QUOTES=("Two years and not one missed delivery slot at our distribution centre.|Supply chain manager, retail"
              "They answer the phone at six in the morning. That matters in this business.|Production planner")
    T_HOURS=("Dispatch|24/7" "Office|Monday – Friday, 7:00 – 19:00" "Warehouse|Monday – Saturday, 6:00 – 22:00")
    T_CTA="Request a quote"; T_CTA2="Our services"
    T_PALETTES=("#ffffff #f1f3f5 #0b1f3a #4f5f75 #0b1f3a #ffffff #ff7a00"
                "#ffd400 #f2c500 #111111 #3d3d3d #111111 #ffd400 #ffffff"
                "#f7f7f7 #e9e9e9 #1a1a1a #5c5c5c #b00d26 #ffffff #1d3557")
    T_FONTS=("condensed;system" "grotesk;grotesk" "slab;system")
    T_MOTIFS=(stripes blocks grid)
}

theme_accounting() {
    T_NAMES=("%s Accounting" "%s Tax and Accounting" "%s Bookkeeping")
    T_FALLBACK=("Ledger Lane" "Balance" "Hartmann" "Clearbook")
    T_LABEL="Services"
    T_TAGLINES=("Bookkeeping, payroll and tax for small businesses" "Accounting for freelancers and small companies")
    T_HERO=("Your books, done properly and on time" "Accounting for small companies and freelancers" "Bookkeeping, payroll and tax returns in one place")
    T_LEAD=("We keep the books for about 180 small businesses and freelancers. You send us documents through a simple online portal; we handle the bookkeeping, payroll and tax filings."
            "A fixed monthly fee, a named accountant and reminders before every deadline. We work in English and Polish and know the rules for foreign founders.")
    T_ABOUT_H=("About the office" "Who we are")
    T_ABOUT=("The office was opened in @YEAR@ by two certified accountants. We now have a team of nine and are licensed by the Ministry of Finance."
             "We prefer plain explanations to long reports. At the end of every month you receive a one-page summary of how your business is doing.")
    T_SERVICES=("Bookkeeping|Monthly recording of invoices, expenses and bank statements.|from 150 EUR per month"
                "Payroll|Salaries, contracts, social security and annual employee statements.|from 25 EUR per employee"
                "Annual accounts|Year-end financial statements and filing with the registry.|from 600 EUR"
                "VAT returns|Monthly or quarterly VAT and EU sales listings.|included"
                "Tax advice for freelancers|Choosing the right tax form and planning your deductions.|from 90 EUR"
                "Company setup|Registration, bank account and the first accounting policies.|from 400 EUR")
    T_STEPS=("Free first call|We look at your business and suggest the right tax form."
             "Simple onboarding|Upload documents through our portal; we take over from your previous accountant."
             "Monthly routine|Bookkeeping, filings and a one-page summary every month.")
    T_QUOTES=("I have not thought about a tax deadline since we started working together.|Freelance designer"
              "They handled our move from sole trader to limited company without a single hiccup.|Owner, e-commerce shop")
    T_HOURS=("Monday – Friday|8:00 – 16:00" "Tax season (March – April)|8:00 – 19:00")
    T_CTA="Get a quote"; T_CTA2="Our services"
    T_PALETTES=("#ffffff #eef4f0 #0f2a1d #4c6357 #17603f #ffffff #c9d66b"
                "#fbfbfd #edf0f7 #1a1f36 #586079 #3d4fa1 #ffffff #f2b84b"
                "#f3f1ec #e4e0d6 #222222 #5f5b52 #0e4d64 #ffffff #d98e04")
    T_FONTS=("transitional;system" "grotesk;system" "classical;transitional")
    T_MOTIFS=(grid stripes blocks)
}

theme_yoga() {
    T_NAMES=("%s Yoga" "%s Yoga Studio" "Studio %s")
    T_FALLBACK=("Still Water" "Lotus Yard" "Prana" "Quiet Room")
    T_LABEL="Classes"
    T_TAGLINES=("Small yoga and pilates classes for every level" "A quiet studio for yoga and pilates")
    T_HERO=("Small classes, plenty of space to breathe" "Yoga and pilates for real bodies" "Come as you are, leave a little lighter")
    T_LEAD=("Classes have no more than twelve people, so teachers know your name and your injuries. Mats, blocks and blankets are provided, and there are showers on site."
            "We teach slow, careful yoga and mat pilates for complete beginners as well as long-time practitioners. The first class is free.")
    T_ABOUT_H=("About the studio" "Our teachers")
    T_ABOUT=("The studio opened in @YEAR@ in a bright attic room with wooden floors. We now have six teachers, all with at least 500 hours of training."
             "We do not do hot rooms or loud music. Our aim is simple: you should leave each class feeling better than when you arrived.")
    T_SERVICES=("Morning flow|A steady vinyasa class to start the day, 60 minutes.|15 EUR"
                "Yin and restore|Long, supported holds and breathing for deep relaxation.|15 EUR"
                "Mat pilates|Core strength, posture and control in a small group.|15 EUR"
                "Beginners course|Six weeks of fundamentals with the same teacher and group.|90 EUR"
                "Pregnancy yoga|Gentle classes from the second trimester onwards.|16 EUR"
                "Private sessions|One-to-one sessions built around your goals or injuries.|55 EUR")
    T_STEPS=("Try a class|Your first class is free; just book a spot online."
             "Choose a pass|Drop-in, a ten-class card or an unlimited monthly membership."
             "Keep practising|Teachers track your progress and suggest the next step.")
    T_QUOTES=("After a year here my back pain is gone and I sleep through the night.|Agnieszka, practising since 2021"
              "The only studio where I never felt out of place as a beginner.|Mark T.")
    T_HOURS=("Monday – Friday|7:00 – 21:00" "Saturday|8:00 – 14:00" "Sunday|9:00 – 12:00")
    T_CTA="Book your first class"; T_CTA2="See the schedule"
    T_PALETTES=("#f7f5ef #e8e6da #2d3328 #646b5c #5d7052 #ffffff #d8b98a"
                "#f8f3f6 #ece1ea #2e2433 #6c5f72 #6b4f7a #ffffff #e7b8a3"
                "#1f2421 #2b322d #ecebe4 #a9aea4 #c9b37e #1f2421 #8fae9a")
    T_FONTS=("classical;classical" "didone;humanist" "humanist;transitional")
    T_MOTIFS=(waves circles petals)
}

theme_interior() {
    T_NAMES=("%s Interiors" "%s Interior Design" "Atelier %s")
    T_FALLBACK=("Linen and Oak" "Maison Blanc" "Sorrel" "Fold")
    T_LABEL="Services"
    T_TAGLINES=("Interior design for homes and boutique hotels" "Rooms that feel calm, practical and personal")
    T_HERO=("Homes that feel like the people who live in them" "Interior design for homes, apartments and small hotels" "Considered rooms, built to be lived in")
    T_LEAD=("We design complete interiors and single rooms: layouts, lighting, joinery, colours and furniture. We manage the builders and suppliers so that you do not have to."
            "We like natural materials, good lighting and furniture that lasts. Every project starts with a long conversation about how you actually use your home.")
    T_ABOUT_H=("About the atelier" "Our approach")
    T_ABOUT=("The atelier was founded in @YEAR@ by an interior architect and a furniture maker. We have since completed more than 140 homes and four small hotels."
             "We work with local workshops for joinery and upholstery, and we reuse existing furniture wherever it makes sense.")
    T_SERVICES=("Full interior design|Concept, drawings, sourcing and site management for the whole home.|from 60 EUR per m²"
                "Kitchens and bathrooms|Detailed plans for the two rooms where mistakes cost the most.|from 1 400 EUR"
                "Furniture sourcing|Pieces chosen for your space, at trade prices where possible.|on request"
                "Colour consultations|A two-hour visit with paint and material samples for every room.|180 EUR"
                "Home staging|Furnishing and styling homes for sale or rental photography.|from 900 EUR"
                "3D visualisation|Realistic images of your future rooms before any work starts.|from 250 EUR per room")
    T_STEPS=("Conversation|A visit to your home to understand how you live and what you need."
             "Design|Mood boards, plans and 3D images, refined together with you."
             "Realisation|We coordinate builders, workshops and deliveries until the last cushion.")
    T_QUOTES=("Our small apartment finally works for a family of four.|Joanna and Michał"
              "They respected the history of the building and our budget.|Owner of a boutique hotel")
    T_HOURS=("Monday – Friday|10:00 – 18:00" "Showroom visits|By appointment")
    T_CTA="Arrange a visit"; T_CTA2="Our services"
    T_PALETTES=("#f5f2ee #e8e1d8 #2a2622 #6f665d #2a2622 #f5f2ee #a8795a"
                "#ffffff #f1efe9 #1d2b2a #5e6b69 #2f5d57 #ffffff #d6a77a"
                "#20232a #2c3038 #eeeae4 #aaa59d #d8c3a5 #20232a #7d9a8c")
    T_FONTS=("didone;classical" "oldstyle;grotesk" "geometric;transitional")
    T_MOTIFS=(arches petals blocks)
}

theme_bikes() {
    T_NAMES=("%s Cycles" "%s Bike Workshop" "%s Bicycle Co.")
    T_FALLBACK=("Chainring" "Freewheel" "Spoke and Hub" "Gravel Road")
    T_LABEL="Workshop"
    T_TAGLINES=("Bicycle repairs, servicing and fitting" "An independent bike workshop")
    T_HERO=("Bike repairs done today, not next week" "An independent workshop for every kind of bike" "Service, repairs and fitting for road, city and e-bikes")
    T_LEAD=("Bring your bike in the morning and most repairs are ready by the evening. We work on road, gravel, mountain, city and electric bikes, whatever the brand."
            "Three mechanics, a well-stocked parts wall and honest advice. We tell you what needs fixing now and what can wait until next season.")
    T_ABOUT_H=("About the workshop" "Who we are")
    T_ABOUT=("The workshop opened in @YEAR@ in a former garage. We still have the garage door, and on warm days it stays open."
             "We are certified for the major e-bike motor systems and we stock spare parts for older bikes that other shops have given up on.")
    T_SERVICES=("Basic service|Gears, brakes, chain and tyres checked and adjusted.|45 EUR"
                "Full service|Complete strip-down, cleaning, bearing service and rebuild.|120 EUR"
                "Wheel truing|Straightening and tensioning a wheel, usually while you wait.|20 EUR"
                "Hydraulic brake bleed|Fresh fluid and properly adjusted pads, per brake.|30 EUR"
                "Bike fitting|Saddle, bars and cleats set up for comfort and power.|120 EUR"
                "E-bike diagnostics|Software updates and error checks for major motor systems.|40 EUR")
    T_STEPS=("Drop it off|No appointment needed for basic repairs before 11:00."
             "We call you|If something unexpected turns up, we ask before fixing it."
             "Ride away|Most bikes are ready the same evening.")
    T_QUOTES=("They saved my old steel frame when two other shops told me to buy a new bike.|Piotr, commuter"
              "Same-day brake repair, fair price and good coffee while I waited.|Lena K.")
    T_HOURS=("Monday – Friday|9:00 – 19:00" "Saturday|10:00 – 15:00" "Sunday|Closed")
    T_CTA="Book a service"; T_CTA2="Workshop prices"
    T_PALETTES=("#ffffff #f0f0ec #151515 #5a5a55 #c81e1e #ffffff #1f6feb"
                "#11181c #1b252b #e8eef1 #9fb0b8 #ffcc00 #11181c #3cb4a4"
                "#f2f5ef #e1e8da #1d261c #5a6658 #2e5e2a #ffffff #f29f05")
    T_FONTS=("condensed;grotesk" "slab;system" "geometric;humanist")
    T_MOTIFS=(rings stripes circles)
}

theme_florist() {
    T_NAMES=("%s Flowers" "%s Florist" "Flower Studio %s")
    T_FALLBACK=("Wild Rose" "Peony and Fern" "Bloom Street" "Meadow")
    T_LABEL="Flowers"
    T_TAGLINES=("Seasonal flowers for homes, offices and weddings" "A small flower studio")
    T_HERO=("Flowers that look like they were just picked" "Seasonal bouquets, arranged by hand" "Fresh flowers for everyday and big days")
    T_LEAD=("We buy flowers twice a week from local growers and the auction, and we arrange them loosely, the way they grow. Same-day delivery across the city for orders before noon."
            "From a single bunch for the kitchen table to the flowers for a two-hundred-guest wedding, every arrangement is made by hand in our studio.")
    T_ABOUT_H=("About the studio" "Our story")
    T_ABOUT=("The studio started in @YEAR@ as a weekend market stall. A few years later we moved into a small shop with a cold room and a workbench by the window."
             "We avoid floral foam and plastic wrapping, and we compost everything we cannot use.")
    T_SERVICES=("Seasonal bouquets|Hand-tied bouquets of whatever is best this week.|from 35 EUR"
                "Weekly office flowers|Fresh arrangements for reception and meeting rooms every Monday.|from 60 EUR per week"
                "Wedding flowers|Bouquets, buttonholes and table flowers, planned with you.|on consultation"
                "Event installations|Large arrangements and hanging installations for venues.|on request"
                "Dried arrangements|Long-lasting bouquets and wreaths from dried flowers and grasses.|from 45 EUR"
                "Plant care visits|Watering, feeding and repotting office plants twice a month.|from 50 EUR per month")
    T_STEPS=("Choose a size|Tell us the occasion, colours you like and your budget."
             "We arrange|Your flowers are made by hand on the morning of delivery."
             "Delivered|Same-day delivery across the city for orders placed before noon.")
    T_QUOTES=("The wedding flowers were exactly what I imagined and could not describe.|Natalia, bride"
              "Our reception has looked alive every Monday for three years.|Office manager, law firm")
    T_HOURS=("Monday – Friday|9:00 – 18:00" "Saturday|9:00 – 14:00" "Sunday|Closed")
    T_CTA="Order flowers"; T_CTA2="Weddings and events"
    T_PALETTES=("#fffaf7 #f8e8e4 #2c1d22 #73606a #a23b5c #ffffff #7ea172"
                "#f7f8f2 #e7ecdd #20291f #5c6858 #3f6b35 #ffffff #e59bb0"
                "#1e1a1d #2b2529 #f4ecef #b9aab2 #e8a0b4 #1e1a1d #9bbf85")
    T_FONTS=("didone;humanist" "oldstyle;classical" "classical;transitional")
    T_MOTIFS=(petals waves circles)
}

theme_renovation() {
    T_NAMES=("%s Renovations" "%s Build" "%s Construction")
    T_FALLBACK=("Solid Ground" "Brick and Beam" "Keystone" "Plumbline")
    T_LABEL="Services"
    T_TAGLINES=("Renovations, extensions and fit-outs" "General contractor for homes and small commercial spaces")
    T_HERO=("Renovations finished on the date we promised" "Kitchens, bathrooms and complete home renovations" "One contractor, one schedule, one fixed price")
    T_LEAD=("We renovate apartments and houses with our own crews: builders, electricians, plumbers and finishers. You get a fixed price and a schedule before work starts."
            "A site manager is on your project every day and sends you photos and progress notes every Friday. We clean up properly at the end of each working day.")
    T_ABOUT_H=("About the company" "Who we are")
    T_ABOUT=("The company was founded in @YEAR@ by a site engineer and a master carpenter. We now employ 28 people and finish around forty projects a year."
             "Every job comes with a written two-year warranty, and we come back to fix anything that is not right.")
    T_SERVICES=("Complete renovations|Apartments and houses stripped back and rebuilt to your design.|from 450 EUR per m²"
                "Kitchens|Removal, new installations, tiling, worktops and fitting.|from 6 500 EUR"
                "Bathrooms|Waterproofing, tiling, plumbing and fittings in about three weeks.|from 5 000 EUR"
                "Loft conversions|Insulation, stairs, windows and finishing of attic spaces.|on survey"
                "Extensions|Foundations to roof, including permits and inspections.|on survey"
                "Electrical and plumbing|New wiring, distribution boards, heating and water systems.|from 60 EUR per hour")
    T_STEPS=("Survey|We visit, measure and discuss what you want to change."
             "Fixed quote|A detailed price and schedule, with no hidden extras."
             "Build|Daily site management and a progress report every Friday.")
    T_QUOTES=("Finished a week early, and the site was cleaner than our old flat.|Marek and Ola"
              "Clear pricing and a site manager who actually answered his phone.|Restaurant owner")
    T_HOURS=("Monday – Friday|7:00 – 17:00" "Saturday|Site visits by appointment")
    T_CTA="Request a survey"; T_CTA2="Our services"
    T_PALETTES=("#ffffff #eef0f2 #1b1f24 #59616b #b45309 #ffffff #1b1f24"
                "#f4f1ea #e6e0d4 #23211d #66615a #2f4858 #ffffff #f6ae2d"
                "#16191d #22272d #eceff1 #a0a8b0 #f6ae2d #16191d #5e8b7e")
    T_FONTS=("condensed;system" "slab;humanist" "grotesk;grotesk")
    T_MOTIFS=(blocks stripes grid)
}

theme_translation() {
    T_NAMES=("%s Translations" "%s Language Services" "%s Translation Bureau")
    T_FALLBACK=("Lingua" "Babel Street" "Wordwise" "Interpres")
    T_LABEL="Services"
    T_TAGLINES=("Certified translation in 30 languages" "Translation and interpreting for companies and individuals")
    T_HERO=("Translations you can sign your name under" "Certified translation and interpreting in 30 languages" "Your documents, accurately translated and on time")
    T_LEAD=("Sworn translators for official documents, specialist translators for legal, medical and technical texts, and interpreters for meetings and court hearings."
            "Every translation is checked by a second linguist before delivery. Send us a scan and receive a price within an hour on working days.")
    T_ABOUT_H=("About the bureau" "Who we are")
    T_ABOUT=("The bureau was founded in @YEAR@ and works with a permanent team of 14 translators and more than 60 freelance specialists."
             "We are certified to ISO 17100 and treat every document as confidential. Files are deleted from our systems 90 days after delivery.")
    T_SERVICES=("Certified translation|Sworn translations of civil, school and court documents.|from 30 EUR per page"
                "Legal and financial|Contracts, annual reports and corporate documents.|from 0.10 EUR per word"
                "Website localisation|Translation and adaptation of websites and online shops.|on request"
                "Technical documentation|Manuals, specifications and safety data sheets.|from 0.09 EUR per word"
                "Interpreting|Consecutive and simultaneous interpreting for meetings and events.|from 80 EUR per hour"
                "Proofreading|Native-speaker review of texts you have already translated.|from 0.04 EUR per word")
    T_STEPS=("Send a scan|Email your document; a photo is enough for a quote."
             "Confirm the price|We reply within an hour with the price and delivery date."
             "Receive the translation|Electronically, or as a stamped paper copy by courier.")
    T_QUOTES=("Our technical manuals in seven languages arrived on time and without a single query from distributors.|Product manager, machinery maker"
              "Quick, careful and they handled the courier for my sworn documents.|Private client")
    T_HOURS=("Monday – Friday|8:00 – 18:00" "Urgent orders|Saturday by arrangement")
    T_CTA="Get a quote"; T_CTA2="Our services"
    T_PALETTES=("#ffffff #f0f3f7 #13233a #55657a #b8322a #ffffff #2e86de"
                "#fbfaf7 #efece4 #1f1f1f #5f5d58 #2b4c7e #ffffff #e1a948"
                "#0f1720 #18232e #e8edf2 #9babbb #6cc0e5 #0f1720 #e0b14d")
    T_FONTS=("transitional;system" "grotesk;transitional" "humanist;humanist")
    T_MOTIFS=(grid waves stripes)
}

# ---------------------------------------------------------------------
#  Шрифтовые пары (Google Fonts)
# ---------------------------------------------------------------------
font_stack() {
    case $1 in
        grotesk)      printf '"Space Grotesk";Space+Grotesk:wght@400;500;700|sans-serif' ;;
        geometric)    printf '"Poppins";Poppins:wght@400;500;600;700|sans-serif' ;;
        humanist)     printf '"Mulish";Mulish:wght@400;600;700;800|sans-serif' ;;
        condensed)    printf '"Oswald";Oswald:wght@400;500;600;700|sans-serif' ;;
        slab)         printf '"Zilla Slab";Zilla+Slab:wght@400;500;600;700|serif' ;;
        oldstyle)     printf '"Spectral";Spectral:wght@400;500;600;700|serif' ;;
        transitional) printf '"Lora";Lora:wght@400;500;600;700|serif' ;;
        didone)       printf '"Playfair Display";Playfair+Display:wght@400;600;700;800|serif' ;;
        classical)    printf '"Cormorant Garamond";Cormorant+Garamond:wght@400;500;600;700|serif' ;;
        mono)         printf '"JetBrains Mono";JetBrains+Mono:wght@400;500;700|monospace' ;;
        *)            printf 'system-ui;|sans-serif' ;;  # system — без Google Fonts
    esac
}

html_escape() {
    local s=$1
    s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}
    printf '%s' "$s"
}

# SVG-орнамент для hero (ненавязчивый фон), $1 — мотив, $2 — цвет-акцент
motif_svg() {
    local kind=$1 c=$2
    case $kind in
        circles) printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><circle cx="150" cy="60" r="80" fill="none" stroke="%s" stroke-width="1.2" opacity=".5"/><circle cx="150" cy="60" r="52" fill="none" stroke="%s" stroke-width="1.2" opacity=".35"/><circle cx="150" cy="60" r="26" fill="none" stroke="%s" stroke-width="1.2" opacity=".25"/></svg>' "$c" "$c" "$c" ;;
        rings)   printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><circle cx="150" cy="70" r="70" fill="none" stroke="%s" stroke-width="18" opacity=".12"/><circle cx="150" cy="70" r="40" fill="none" stroke="%s" stroke-width="10" opacity=".2"/></svg>' "$c" "$c" ;;
        waves)   printf '<svg class="motif" viewBox="0 0 240 200" preserveAspectRatio="none" aria-hidden="true"><path d="M0 120 Q60 80 120 120 T240 120" fill="none" stroke="%s" stroke-width="1.4" opacity=".5"/><path d="M0 150 Q60 110 120 150 T240 150" fill="none" stroke="%s" stroke-width="1.4" opacity=".35"/><path d="M0 90 Q60 50 120 90 T240 90" fill="none" stroke="%s" stroke-width="1.4" opacity=".25"/></svg>' "$c" "$c" "$c" ;;
        grid)    printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><g stroke="%s" stroke-width="1" opacity=".3">%s</g></svg>' "$c" "$(for i in 0 1 2 3 4 5 6; do printf '<line x1="%d" y1="0" x2="%d" y2="200"/><line x1="0" y1="%d" x2="200" y2="%d"/>' $((i*30)) $((i*30)) $((i*30)) $((i*30)); done)" ;;
        blocks)  printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><g fill="%s"><rect x="120" y="20" width="60" height="60" opacity=".18"/><rect x="60" y="90" width="60" height="60" opacity=".12"/><rect x="130" y="110" width="40" height="40" opacity=".2"/></g></svg>' "$c" ;;
        stripes) printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><g stroke="%s" stroke-width="10" opacity=".14">%s</g></svg>' "$c" "$(for i in 0 1 2 3 4 5 6 7; do printf '<line x1="%d" y1="0" x2="%d" y2="200"/>' $((i*28+10)) $((i*28+10)); done)" ;;
        arches)  printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><g fill="none" stroke="%s" stroke-width="1.4" opacity=".4"><path d="M40 190 V90 a40 40 0 0 1 80 0 V190"/><path d="M90 190 V70 a50 50 0 0 1 100 0 V190"/></g></svg>' "$c" ;;
        petals)  printf '<svg class="motif" viewBox="0 0 200 200" aria-hidden="true"><g fill="none" stroke="%s" stroke-width="1.3" opacity=".45">%s</g></svg>' "$c" "$(for a in 0 60 120 180 240 300; do printf '<ellipse cx="150" cy="70" rx="14" ry="42" transform="rotate(%d 150 70)"/>' "$a"; done)" ;;
        *)       printf '' ;;
    esac
}

# Собирает один index.html. Пишет в $1 (путь к файлу).
generate_site() {
    local out=$1 theme=$2
    "theme_$theme"

    # --- случайный выбор составляющих ---
    local name_tpl fb pal fonts motif hero lead about_h tagline cta cta2
    pickv name_tpl "${T_NAMES[@]}"
    pickv fb "${T_FALLBACK[@]}"
    pickv pal "${T_PALETTES[@]}"
    pickv fonts "${T_FONTS[@]}"
    pickv motif "${T_MOTIFS[@]}"
    pickv hero "${T_HERO[@]}"
    pickv lead "${T_LEAD[@]}"
    local about_idx=$((RANDOM % ${#T_ABOUT[@]}))
    about_h=${T_ABOUT_H[about_idx]}
    local about=${T_ABOUT[about_idx]}
    pickv tagline "${T_TAGLINES[@]}"
    cta=$T_CTA; cta2=$T_CTA2
    local layout=$((RANDOM % 3))      # 0 left-rail, 1 centered, 2 split
    local year=$((2008 + RANDOM % 14))
    local brand_short
    # подставляем выдуманное имя в шаблон названия
    local brand
    # name_tpl — наш собственный шаблон вида "%s Coffee Roasters" (не ввод пользователя)
    # shellcheck disable=SC2059
    printf -v brand "$name_tpl" "$fb"
    brand_short=${fb%% *}

    # цвета
    read -r C_BG C_SURF C_INK C_MUTE C_ACC C_ONACC C_ACC2 <<<"$pal"
    local f_disp f_body
    IFS=';' read -r f_disp f_body <<<"$fonts"
    local disp_fam disp_imp body_fam body_imp
    IFS='|' read -r disp_fam disp_imp <<<"$(font_stack "$f_disp")"
    IFS='|' read -r body_fam body_imp <<<"$(font_stack "$f_body")"

    # Google Fonts <link>
    local gf=""
    local gfparts=()
    [[ $disp_imp != "" ]] && gfparts+=("$disp_imp")
    [[ $body_imp != "" && $body_imp != "$disp_imp" ]] && gfparts+=("$body_imp")
    if ((${#gfparts[@]})); then
        local qs=""
        local part
        for part in "${gfparts[@]}"; do qs+="family=$part&"; done
        gf="<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\"><link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin><link href=\"https://fonts.googleapis.com/css2?${qs}display=swap\" rel=\"stylesheet\">"
    fi

    local serif_body=0
    [[ $body_fam == *serif* || $f_body == oldstyle || $f_body == transitional || $f_body == classical || $f_body == didone || $f_body == slab ]] && serif_body=1

    # --- строим секции в переменные ---
    local nav_links
    nav_links="<a href=\"#services\">$(html_escape "$T_LABEL")</a><a href=\"#about\">About</a><a href=\"#contact\">Contact</a>"

    # services (3–6 случайно, но минимум 3)
    local n_serv=$(( 3 + RANDOM % (${#T_SERVICES[@]} - 2) ))
    ((n_serv > ${#T_SERVICES[@]})) && n_serv=${#T_SERVICES[@]}
    local services_html="" i
    local shuffled=()
    mapfile -t shuffled < <(printf '%s\n' "${T_SERVICES[@]}" | shuf)
    for ((i = 0; i < n_serv; i++)); do
        local st sd sp
        IFS='|' read -r st sd sp <<<"${shuffled[i]}"
        services_html+="<article class=\"svc\"><div class=\"svc-head\"><h3>$(html_escape "$st")</h3><span class=\"price\">$(html_escape "$sp")</span></div><p>$(html_escape "$sd")</p></article>"
    done

    # steps (нумерованная последовательность — numbering уместно)
    local steps_html="" sn=0
    for st in "${T_STEPS[@]}"; do
        sn=$((sn + 1))
        local sh sb
        IFS='|' read -r sh sb <<<"$st"
        steps_html+="<li><span class=\"step-n\">$sn</span><div><h4>$(html_escape "$sh")</h4><p>$(html_escape "$sb")</p></div></li>"
    done

    # quote
    local q qtext qauthor
    pickv q "${T_QUOTES[@]}"
    IFS='|' read -r qtext qauthor <<<"$q"

    # hours
    local hours_html=""
    for h in "${T_HOURS[@]}"; do
        local hd hv
        IFS='|' read -r hd hv <<<"$h"
        hours_html+="<div class=\"hrow\"><span>$(html_escape "$hd")</span><span>$(html_escape "$hv")</span></div>"
    done

    about=${about//@YEAR@/$year}
    tagline=${tagline//@YEAR@/$year}

    # контакты (выдуманные, формат под домен)
    local phone email_c addr
    printf -v phone '+48 %d %03d %02d %02d' $((500 + RANDOM % 400)) $((RANDOM % 1000)) $((RANDOM % 100)) $((RANDOM % 100))
    email_c="hello@$DOMAIN"
    local streets=("Market Street" "Grove Road" "Harbour Lane" "Mill Yard" "Garden Row" "Station Street" "Chapel Walk" "Linden Avenue")
    local cities=("Kraków" "Gdańsk" "Wrocław" "Poznań" "Warsaw" "Lublin" "Katowice")
    local stt ct
    pickv stt "${streets[@]}"
    pickv ct "${cities[@]}"
    addr="$((RANDOM % 180 + 1)) $stt, $ct"

    local motif_markup
    motif_markup=$(motif_svg "$motif" "$C_ACC")

    # заголовок hero по макету
    local hero_align="left"
    case $layout in
        1) hero_align="center" ;;
        *) hero_align="left" ;;
    esac

    # --- запись файла ---
    {
    cat <<HTMLHEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(html_escape "$brand")</title>
<meta name="description" content="$(html_escape "$tagline")">
$gf
<style>
:root{
  --bg:$C_BG; --surface:$C_SURF; --ink:$C_INK; --muted:$C_MUTE;
  --accent:$C_ACC; --on-accent:$C_ONACC; --accent-2:$C_ACC2;
  --line:color-mix(in srgb, var(--ink) 14%, transparent);
  --maxw:1100px; --radius:$(( RANDOM % 2 ? 14 : 4 ))px;
  --font-display:$disp_fam, Georgia, serif;
  --font-body:$body_fam, system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--font-body);
  line-height:$([ $serif_body -eq 1 ] && echo 1.7 || echo 1.6);font-size:17px;-webkit-font-smoothing:antialiased}
h1,h2,h3,h4{font-family:var(--font-display);line-height:1.1;margin:0;font-weight:700}
h1{font-size:clamp(2.2rem,5.4vw,4rem);letter-spacing:-.01em}
h2{font-size:clamp(1.6rem,3.2vw,2.3rem);letter-spacing:-.01em}
h3{font-size:1.18rem}
p{margin:0 0 1rem}
a{color:inherit;text-decoration:none}
img{max-width:100%;display:block}
.wrap{max-width:var(--maxw);margin:0 auto;padding:0 clamp(18px,5vw,40px)}
.btn{display:inline-block;padding:.85em 1.5em;border-radius:var(--radius);font-weight:600;
  font-family:var(--font-body);cursor:pointer;border:1.5px solid transparent;transition:transform .15s ease,background .15s ease}
.btn-primary{background:var(--accent);color:var(--on-accent)}
.btn-primary:hover{transform:translateY(-2px)}
.btn-ghost{border-color:var(--line);color:var(--ink)}
.btn-ghost:hover{border-color:var(--accent);color:var(--accent)}
:focus-visible{outline:3px solid var(--accent);outline-offset:3px}

header.nav{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--bg) 88%,transparent);
  backdrop-filter:saturate(1.2) blur(8px);border-bottom:1px solid var(--line)}
.nav .wrap{display:flex;align-items:center;justify-content:space-between;height:68px}
.brand{font-family:var(--font-display);font-weight:700;font-size:1.3rem;letter-spacing:-.01em}
.brand .dot{color:var(--accent)}
.nav nav{display:flex;gap:1.6rem;align-items:center}
.nav nav a{color:var(--muted);font-size:.97rem}
.nav nav a:hover{color:var(--ink)}
.nav nav a.btn-primary{color:var(--on-accent)}
.nav nav a.btn-primary:hover{color:var(--on-accent)}
.nav .btn{padding:.55em 1.1em}
.navtoggle{display:none;background:none;border:0;color:var(--ink);font-size:1.5rem;cursor:pointer}

.hero{position:relative;overflow:hidden;border-bottom:1px solid var(--line)}
.hero .wrap{padding-top:clamp(56px,9vw,120px);padding-bottom:clamp(56px,9vw,120px);position:relative;z-index:2}
.hero.center .wrap{text-align:center;max-width:820px}
.hero .tagline{color:var(--accent);font-weight:600;margin:0 0 1rem;font-size:1.02rem}
.hero p.lead{font-size:1.2rem;color:var(--muted);max-width:60ch;margin:1.4rem 0 2rem}
.hero.center p.lead{margin-left:auto;margin-right:auto}
.hero .cta{display:flex;gap:.9rem;flex-wrap:wrap}
.hero.center .cta{justify-content:center}
.motif{position:absolute;right:-40px;top:0;height:100%;width:min(46%,520px);z-index:1;pointer-events:none}
.hero.center .motif{right:auto;left:50%;transform:translateX(-50%);opacity:.5;width:min(80%,640px)}

section{padding:clamp(52px,8vw,96px) 0}
.sec-head{max-width:62ch;margin-bottom:2.6rem}
.sec-head h2{margin-bottom:.8rem}
.sec-head p{color:var(--muted);margin:0}

.grid-svc{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:clamp(14px,2vw,22px)}
.svc{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:1.5rem 1.4rem;
  display:flex;flex-direction:column;gap:.5rem}
.svc-head{display:flex;justify-content:space-between;align-items:baseline;gap:1rem}
.svc h3{margin:0}
.svc .price{color:var(--accent);font-weight:600;font-size:.92rem;white-space:nowrap}
.svc p{color:var(--muted);margin:0;font-size:.97rem}

.about{background:var(--surface);border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
.about .cols{display:grid;grid-template-columns:1.2fr 1fr;gap:clamp(28px,5vw,64px);align-items:start}
.about .meta{border-left:3px solid var(--accent);padding-left:1.4rem}
.about .meta dt{color:var(--muted);font-size:.86rem;margin-top:1rem}
.about .meta dd{margin:.15rem 0 0;font-weight:600}

.steps{counter-reset:s;list-style:none;padding:0;margin:0;display:grid;gap:1.4rem;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
.steps li{display:flex;gap:1rem;align-items:flex-start}
.step-n{flex:none;width:2.4rem;height:2.4rem;border-radius:50%;display:grid;place-items:center;
  background:var(--accent);color:var(--on-accent);font-family:var(--font-display);font-weight:700}
.steps h4{margin:.2rem 0 .3rem;font-size:1.05rem}
.steps p{color:var(--muted);margin:0;font-size:.95rem}

.quote{background:var(--ink);color:var(--bg)}
.quote .wrap{text-align:center;max-width:800px}
.quote blockquote{font-family:var(--font-display);font-size:clamp(1.4rem,3vw,2rem);line-height:1.3;margin:0}
.quote cite{display:block;margin-top:1.4rem;color:color-mix(in srgb,var(--bg) 70%,var(--accent));font-style:normal;font-size:1rem}

.contact .cols{display:grid;grid-template-columns:1fr 1fr;gap:clamp(28px,5vw,56px)}
.contact .hours{display:flex;flex-direction:column;gap:.1rem}
.hrow{display:flex;justify-content:space-between;padding:.7rem 0;border-bottom:1px solid var(--line)}
.hrow span:last-child{color:var(--muted)}
.cfield{display:block;margin-bottom:1rem}
.cfield label{display:block;font-size:.9rem;margin-bottom:.35rem;color:var(--muted)}
.cfield input,.cfield textarea{width:100%;padding:.75em .9em;border:1px solid var(--line);border-radius:var(--radius);
  background:var(--bg);color:var(--ink);font:inherit}
.contact .info p{color:var(--muted)}
.contact .info a{color:var(--accent)}

footer.site{border-top:1px solid var(--line);padding:2.4rem 0;color:var(--muted);font-size:.92rem}
footer.site .wrap{display:flex;justify-content:space-between;flex-wrap:wrap;gap:1rem}

@media(max-width:760px){
  .nav nav{display:none}
  .nav nav.open{display:flex;position:absolute;top:68px;left:0;right:0;flex-direction:column;
    background:var(--bg);border-bottom:1px solid var(--line);padding:1rem clamp(18px,5vw,40px);gap:1rem}
  .navtoggle{display:block}
  .about .cols,.contact .cols{grid-template-columns:1fr}
  .motif{opacity:.35;width:70%}
}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
</style>
</head>
<body>
<header class="nav">
  <div class="wrap">
    <a class="brand" href="#top">$(html_escape "$brand_short")<span class="dot">.</span></a>
    <nav id="menu">$nav_links<a class="btn btn-primary" href="#contact">$(html_escape "$cta")</a></nav>
    <button class="navtoggle" aria-label="Menu" aria-expanded="false" onclick="var m=document.getElementById('menu');var o=m.classList.toggle('open');this.setAttribute('aria-expanded',o)">≡</button>
  </div>
</header>

<main id="top">
<section class="hero $([ "$hero_align" = center ] && echo center)">
  $motif_markup
  <div class="wrap">
    <p class="tagline">$(html_escape "$tagline")</p>
    <h1>$(html_escape "$hero")</h1>
    <p class="lead">$(html_escape "$lead")</p>
    <div class="cta">
      <a class="btn btn-primary" href="#contact">$(html_escape "$cta")</a>
      <a class="btn btn-ghost" href="#services">$(html_escape "$cta2")</a>
    </div>
  </div>
</section>

<section id="services">
  <div class="wrap">
    <div class="sec-head"><h2>$(html_escape "$T_LABEL")</h2><p>$(html_escape "$tagline").</p></div>
    <div class="grid-svc">$services_html</div>
  </div>
</section>

<section class="about" id="about">
  <div class="wrap">
    <div class="cols">
      <div>
        <div class="sec-head"><h2>$(html_escape "$about_h")</h2></div>
        <p>$(html_escape "$about")</p>
      </div>
      <dl class="meta">
        <dt>Founded</dt><dd>$year</dd>
        <dt>Where</dt><dd>$(html_escape "$ct")</dd>
        <dt>Get in touch</dt><dd>$(html_escape "$phone")</dd>
      </dl>
    </div>
    <ol class="steps" style="margin-top:3rem">$steps_html</ol>
  </div>
</section>

<section class="quote">
  <div class="wrap">
    <blockquote>&ldquo;$(html_escape "$qtext")&rdquo;</blockquote>
    <cite>— $(html_escape "$qauthor")</cite>
  </div>
</section>

<section class="contact" id="contact">
  <div class="wrap">
    <div class="sec-head"><h2>$(html_escape "$cta")</h2><p>Send a message or drop by — we usually reply the same working day.</p></div>
    <div class="cols">
      <div class="info">
        <div class="cfield"><label>Name</label><input type="text" autocomplete="name"></div>
        <div class="cfield"><label>Email</label><input type="email" autocomplete="email"></div>
        <div class="cfield"><label>Message</label><textarea rows="4"></textarea></div>
        <button class="btn btn-primary" type="button" onclick="this.textContent='Thanks — we\'ll be in touch'">$(html_escape "$cta")</button>
      </div>
      <div class="info">
        <p><strong>$(html_escape "$addr")</strong></p>
        <p>Phone: <a href="tel:${phone// /}">$(html_escape "$phone")</a><br>
           Email: <a href="mailto:$email_c">$(html_escape "$email_c")</a></p>
        <div class="hours" style="margin-top:1.4rem">$hours_html</div>
      </div>
    </div>
  </div>
</section>
</main>

<footer class="site">
  <div class="wrap">
    <span>&copy; $year $(html_escape "$brand"). All rights reserved.</span>
    <span>$(html_escape "$addr")</span>
  </div>
</footer>
</body>
</html>
HTMLHEAD
    } >"$out"

    SITE_INFO="${THEME_RU[$theme]:-$theme} · «$brand»"
}

# ---------------------------------------------------------------------
#  Размещение контента сайта
# ---------------------------------------------------------------------
site_dir() { printf '%s/%s' "$SITES_ROOT" "$DOMAIN"; }

deploy_content() {
    step "Подготовка сайта-маскировки..."
    local dir
    dir=$(site_dir)
    mkdir -p "$dir"

    case $TEMPLATE in
        keep)
            if [[ -f "$dir/index.html" ]]; then
                ok "Оставлен текущий сайт: $dir"
            else
                warn "В $dir нет index.html — генерирую случайный сайт"
                TEMPLATE=random
                deploy_content
                return
            fi
            ;;
        /*)
            [[ -f "$TEMPLATE/index.html" ]] || die "В папке $TEMPLATE нет index.html"
            rm -rf "${dir:?}/"*
            cp -rT "$TEMPLATE" "$dir" || die "Не удалось скопировать $TEMPLATE"
            ok "Установлен ваш сайт из $TEMPLATE"
            ;;
        github)
            deploy_github "$dir"
            ;;
        *)
            # random или конкретная тематика
            local theme=$TEMPLATE
            if [[ -z $theme || $theme == random ]]; then
                pickv theme "${THEMES[@]}"
            fi
            local known=0 t
            for t in "${THEMES[@]}"; do [[ $t == "$theme" ]] && known=1; done
            ((known)) || die "Неизвестная тематика: $theme" "Список тематик: bash fakesite.sh --themes"
            rm -rf "${dir:?}/"*
            generate_site "$dir/index.html" "$theme"
            printf 'User-agent: *\nDisallow:\n' >"$dir/robots.txt"
            ok "Сгенерирован сайт: $SITE_INFO"
            ;;
    esac
    chown -R www-data:www-data "$dir" 2>/dev/null || true
    find "$dir" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$dir" -type f -exec chmod 644 {} + 2>/dev/null || true
}

deploy_github() {
    local dir=$1 tmp
    command -v git >/dev/null 2>&1 || die "Для шаблонов github нужен git" "Установите: apt-get install -y git"
    tmp=$(mktemp_dir)
    local repo="https://github.com/learning-zone/website-templates.git"
    # Экономный способ: берём список папок и выгружаем только одну (sparse checkout)
    if run git -C "$tmp" init -q && run git -C "$tmp" remote add origin "$repo" &&
       run git -C "$tmp" config core.sparseCheckout true; then
        # получаем список шаблонов (верхнеуровневые папки)
        local list pick
        list=$(git ls-remote -q "$repo" HEAD >/dev/null 2>&1; git -C "$tmp" ls-tree -d --name-only origin/master 2>/dev/null)
        if [[ -z $list ]]; then
            run git -C "$tmp" fetch --depth 1 -q origin master || die "Не удалось получить список шаблонов с GitHub"
            list=$(git -C "$tmp" ls-tree -d --name-only FETCH_HEAD 2>/dev/null)
        fi
        list=$(grep -viE '^(assets|_|\.)' <<<"$list")
        pick=$(shuf -n1 <<<"$list")
        [[ -n $pick ]] || die "Пустой список шаблонов GitHub"
        printf '%s/*\n' "$pick" >"$tmp/.git/info/sparse-checkout"
        run git -C "$tmp" fetch --depth 1 -q origin master &&
        run git -C "$tmp" checkout -q FETCH_HEAD -- "$pick" || die "Не удалось выгрузить шаблон $pick"
        rm -rf "${dir:?}/"*
        cp -rT "$tmp/$pick" "$dir"
        [[ -f "$dir/index.html" ]] || { local idx; idx=$(find "$dir" -iname index.html | head -n1); [[ -n $idx ]] && cp "$idx" "$dir/index.html"; }
        [[ -f "$dir/index.html" ]] || die "В шаблоне $pick не нашёлся index.html"
        SITE_INFO="GitHub-шаблон «$pick»"
        ok "Установлен готовый шаблон: $pick"
    else
        die "Не удалось подготовить git-репозиторий для шаблона"
    fi
}

# ---------------------------------------------------------------------
#  Let's Encrypt
# ---------------------------------------------------------------------
obtain_cert() {
    step "Получение SSL-сертификата Let's Encrypt..."
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        local days
        days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
        if ((days > 30)); then
            ok "Сертификат уже есть и годен ещё $days дн. — повторный выпуск не нужен"
            return 0
        fi
    fi

    # webroot: nginx уже обслуживает ACME через отдельный server {} (поднят до выпуска)
    mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
    chown -R www-data:www-data "$ACME_ROOT" 2>/dev/null || true

    local email_args
    if [[ -n $EMAIL ]]; then
        email_args=(-m "$EMAIL")
    else
        email_args=(--register-unsafely-without-email)
    fi

    if run certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
            --non-interactive --agree-tos --no-eff-email --keep-until-expiring "${email_args[@]}"; then
        ok "Сертификат получен: /etc/letsencrypt/live/$DOMAIN/"
    else
        show_log_tail
        die "Не удалось получить сертификат Let's Encrypt" \
            "Проверьте, что порт 80 открыт в файрволе и у хостера (ufw allow 80/tcp)" \
            "Убедитесь, что A-запись $DOMAIN указывает на этот сервер ($IPV4)" \
            "Если это тест — у Let's Encrypt лимит 5 сертификатов на домен в неделю" \
            "Полный лог: $LOG_FILE"
    fi
}

setup_renewal() {
    # deploy-hook перезагружает nginx после продления
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh

    if systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
        run systemctl enable --now certbot.timer
        if ! systemctl cat certbot.timer 2>/dev/null | grep -q 'Persistent=true'; then
            mkdir -p /etc/systemd/system/certbot.timer.d
            printf '[Timer]\nPersistent=true\n' >/etc/systemd/system/certbot.timer.d/override.conf
            run systemctl daemon-reload
            run systemctl restart certbot.timer
        fi
        log "Автопродление: systemd timer"
    elif [[ -f /etc/cron.d/certbot ]]; then
        log "Автопродление: системный cron"
    else
        cat >/etc/cron.d/selfsni-certbot <<'CRON'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
17 3,15 * * * root certbot -q renew
CRON
        log "Автопродление: добавлен cron /etc/cron.d/selfsni-certbot"
    fi
}

# ---------------------------------------------------------------------
#  Конфиг Nginx
# ---------------------------------------------------------------------
NGINX_CONF_NAME="selfsni-$DOMAIN"
NGINX_CONF_FILE=""
NGINX_CONF_LINK=""
OLD_CONFIGS=()

init_nginx_paths() {
    NGINX_CONF_NAME="selfsni-$DOMAIN"
    NGINX_CONF_FILE="$NGINX_AVAIL/$NGINX_CONF_NAME.conf"
    NGINX_CONF_LINK="$NGINX_ENABLED/$NGINX_CONF_NAME.conf"
    # старый конфиг прошлых версий скрипта — чтобы не конфликтовал
    OLD_CONFIGS=("$NGINX_ENABLED/sni.conf" "$NGINX_AVAIL/sni.conf")
}

# Есть ли у сервера IPv6-стек (иначе listen [::] уронит nginx)
HAS_IPV6=""
server_has_ipv6() {
    if [[ -z $HAS_IPV6 ]]; then
        if has_ipv6_stack && ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
            HAS_IPV6=1
        else
            HAS_IPV6=0
        fi
        log "IPv6 на сервере: $HAS_IPV6"
    fi
    ((HAS_IPV6))
}

# Временный конфиг только для ACME на порту 80 (до выпуска сертификата)
write_acme_only_conf() {
    local v6=""
    server_has_ipv6 && v6=$'\n    listen [::]:80;'
    cat >"$NGINX_CONF_FILE" <<EOF
# selfsni: временно, только для проверки Let's Encrypt
server {
    listen 80;$v6
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF
    link_and_reload
}

# Итоговый конфиг
write_final_conf() {
    local dir
    dir=$(site_dir)
    local pp="" proto_real=""
    ((PROXY_PROTOCOL)) && pp=" proxy_protocol"

    # собираем listen-строки (IPv6 — только если он реально есть)
    local listen_line
    if [[ $MODE == reality ]]; then
        listen_line="listen 127.0.0.1:$SPORT ssl${pp};"
        server_has_ipv6 && listen_line+=$'\n    listen [::1]:'"$SPORT"" ssl${pp};"
        if ((PROXY_PROTOCOL)); then
            proto_real=$'    set_real_ip_from 127.0.0.1;\n'
            server_has_ipv6 && proto_real+=$'    set_real_ip_from ::1;\n'
            proto_real+=$'    real_ip_header proxy_protocol;\n'
        fi
    else
        listen_line="listen 443 ssl;"
        server_has_ipv6 && listen_line+=$'\n    listen [::]:443 ssl;'
    fi

    # HTTP/2: с nginx 1.25.1 — отдельная директива, раньше — флаг в listen.
    # http2 ставим только на публичных TCP-сокетах (в direct) — на loopback
    # (reality) он бессмысленен, а с proxy_protocol может мешать.
    local http2_line
    if nginx_version_ge 1.25.1; then
        if [[ $MODE == direct ]]; then
            http2_line="http2 on;"
        else
            http2_line="# http2 off (внутренний loopback для Reality)"
        fi
    else
        [[ $MODE == direct ]] && listen_line=${listen_line//ssl;/ssl http2;}
        http2_line="# http2 управляется в директиве listen (nginx < 1.25.1)"
    fi

    local v6_80=""
    server_has_ipv6 && v6_80=$'\n    listen [::]:80;'

    cat >"$NGINX_CONF_FILE" <<EOF
# ====================================================================
#  Self SNI Scripts — $DOMAIN
#  Режим: $MODE$([[ $MODE == reality ]] && echo " (Xray слушает 443, Dest = 127.0.0.1:$SPORT)")
#  Сгенерировано $(date '+%F %T'). Не редактируйте вручную — перезапишется.
# ====================================================================

# Порт 80: ACME (продление сертификата) + редирект людей на https
server {
    listen 80;$v6_80
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Сайт-маскировка (TLS)
server {
    $listen_line
    $http2_line
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SelfSNI:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

$proto_real    root $dir;
    index index.html index.htm;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(?:css|js|woff2?|ttf|otf|eot|svg|jpg|jpeg|png|gif|webp|avif|ico)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800";
        access_log off;
        try_files \$uri =404;
    }

    location = /50x.html { internal; }
    error_page 500 502 503 504 /50x.html;
}
EOF
    link_and_reload
}

link_and_reload() {
    mkdir -p "$NGINX_ENABLED" "$NGINX_AVAIL"
    ln -sf "$NGINX_CONF_FILE" "$NGINX_CONF_LINK"
    # уберём конфликтующие дефолтные/старые
    rm -f "$NGINX_ENABLED/default" 2>/dev/null
    local oc
    for oc in "${OLD_CONFIGS[@]}"; do [[ -e $oc ]] && { backup_file "$oc"; rm -f "$oc"; }; done
    if ! run nginx -t; then
        show_log_tail
        die "Nginx отклонил конфигурацию" "Проверьте вручную: nginx -t" "Конфиг: $NGINX_CONF_FILE"
    fi
    if systemctl is-active --quiet nginx; then
        run systemctl reload nginx || { run systemctl restart nginx || die "Не удалось перезапустить nginx"; }
    else
        run systemctl enable --now nginx || die "Не удалось запустить nginx"
    fi
}

backup_file() {
    local f=$1
    [[ -e $f ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s).bak" 2>/dev/null || true
}

# ---------------------------------------------------------------------
#  Самопроверка: действительно ли сайт отдаётся по тому же SNI
#  (это и был главный баг — раньше сайт слушал только 127.0.0.1 и
#   извне не открывался; проверяем именно внутренний TLS-эндпоинт)
# ---------------------------------------------------------------------
verify_site() {
    step "Проверка, что сайт отвечает..."
    local code ok_local=0 ok_public=0

    # локальная проверка внутреннего TLS-эндпоинта (resolve на loopback, SNI = домен)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
        --resolve "$DOMAIN:${SPORT:-443}:127.0.0.1" \
        --cacert "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
        "https://$DOMAIN:${SPORT:-443}/" 2>/dev/null) || code=000
    [[ $code =~ ^(200|301|302|304)$ ]] && ok_local=1

    if ((ok_local)); then
        ok "Сайт отвечает на внутреннем TLS-эндпоинте (HTTP $code)"
    else
        warn "Внутренний TLS-эндпоинт не ответил как ожидалось (код $code)"
        hint "Логи nginx: journalctl -u nginx -n 30 --no-pager"
    fi

    # внешняя проверка (как увидит клиент/Xray), только при reality — через 80→443 нельзя,
    # поэтому проверяем публичный 443 лишь в режиме direct
    if [[ $MODE == direct ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null) || code=000
        [[ $code =~ ^(200|301|302|304)$ ]] && { ok_public=1; ok "Публично доступен https://$DOMAIN (HTTP $code)"; }
        ((ok_public)) || warn "Снаружи https://$DOMAIN пока не открылся (код $code) — возможно, файрвол хостера"
    fi
}

# ---------------------------------------------------------------------
#  Итог
# ---------------------------------------------------------------------
print_summary() {
    printf '\n%s%s=====================================================%s\n' "$BOLD" "$CYAN" "$NC"
    printf '%s%s          Установка завершена успешно!%s\n' "$BOLD" "$CYAN" "$NC"
    printf '%s%s=====================================================%s\n\n' "$BOLD" "$CYAN" "$NC"

    printf '%sСайт-маскировка:%s %s\n' "$GREEN" "$NC" "$SITE_INFO"
    printf '%sФайлы сайта:%s     %s\n\n' "$GREEN" "$NC" "$(site_dir)"

    printf '%sПараметры для Xray Reality:%s\n' "$GREEN" "$NC"
    printf '%s-----------------------------------------------------%s\n' "$BLUE" "$NC"
    if [[ $MODE == reality ]]; then
        printf ' %sdest / target:%s   127.0.0.1:%s\n' "$YELLOW" "$NC" "$SPORT"
        printf ' %sserverNames:%s     ["%s"]\n' "$YELLOW" "$NC" "$DOMAIN"
        ((PROXY_PROTOCOL)) && printf ' %sв Xray outbound:%s xver: 1 (PROXY protocol включён)\n' "$YELLOW" "$NC"
    fi
    printf ' %sSNI:%s             %s\n' "$YELLOW" "$NC" "$DOMAIN"
    printf ' %sСертификат:%s      %s\n' "$YELLOW" "$NC" "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    printf ' %sКлюч:%s            %s\n' "$YELLOW" "$NC" "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    printf '%s-----------------------------------------------------%s\n\n' "$BLUE" "$NC"

    if [[ $MODE == reality ]]; then
        note "В 3x-ui/Marzban укажите dest (target): 127.0.0.1:$SPORT, SNI: $DOMAIN"
        note "Xray должен слушать 443 и проксировать рукопожатие на этот target."
    else
        note "Проверить снаружи: откройте https://$DOMAIN в браузере."
    fi
    printf '%sЛог установки:%s %s\n' "$BLUE" "$NC" "$LOG_FILE"
    printf '\n%sГотово. Спасибо, что пользуетесь Self SNI Scripts!%s\n' "$GREEN" "$NC"
}

# ---------------------------------------------------------------------
#  Диагностика (--check)
# ---------------------------------------------------------------------
do_check() {
    [[ -n $DOMAIN ]] || ask DOMAIN "Домен для диагностики: " ""
    DOMAIN=$(normalize_domain "$DOMAIN")
    valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"
    init_nginx_paths

    printf '\n%s== Диагностика %s ==%s\n\n' "$BOLD" "$DOMAIN" "$NC"

    local conf=""
    [[ -f $NGINX_CONF_FILE ]] && conf=$NGINX_CONF_FILE
    [[ -z $conf && -f "$NGINX_ENABLED/sni.conf" ]] && conf="$NGINX_ENABLED/sni.conf"
    if [[ -n $conf ]]; then
        printf '%s✓%s Конфиг nginx: %s\n' "$GREEN" "$NC" "$conf"
        local port
        port=$(grep -oE 'listen[^;]*' "$conf" | grep -oE '(127\.0\.0\.1:)?[0-9]{2,5}' | grep -vE '^80$' | head -n1)
        printf '  порт прослушивания: %s\n' "${port:-не найден}"
    else
        printf '%s✗%s Конфиг nginx для %s не найден\n' "$RED" "$NC" "$DOMAIN"
    fi

    if systemctl is-active --quiet nginx; then
        printf '%s✓%s nginx запущен\n' "$GREEN" "$NC"
    else
        printf '%s✗%s nginx не запущен (systemctl status nginx)\n' "$RED" "$NC"
    fi
    nginx -t >/dev/null 2>&1 && printf '%s✓%s nginx -t: конфигурация валидна\n' "$GREEN" "$NC" \
        || printf '%s✗%s nginx -t выдаёт ошибку\n' "$RED" "$NC"

    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        local days
        days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
        printf '%s✓%s Сертификат есть, годен ещё %s дн.\n' "$GREEN" "$NC" "$days"
    else
        printf '%s✗%s Сертификата для %s нет\n' "$RED" "$NC" "$DOMAIN"
    fi

    # внутренние порты
    local p
    for p in 80 443 "$SPORT" 9000; do
        [[ -z $p ]] && continue
        if port_busy "$p"; then
            printf '  порт %-5s занят: %s\n' "$p" "$(port_owner "$p")"
        fi
    done

    # пробуем сам сайт на известных портах
    local sport
    sport=$(grep -oE '127\.0\.0\.1:[0-9]+' "${conf:-/dev/null}" 2>/dev/null | grep -oE '[0-9]+$' | head -n1)
    if [[ -n $sport ]]; then
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
            --resolve "$DOMAIN:$sport:127.0.0.1" \
            --cacert "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
            "https://$DOMAIN:$sport/" 2>/dev/null) || code=000
        if [[ $code =~ ^(200|301|302)$ ]]; then
            printf '%s✓%s Сайт отвечает на 127.0.0.1:%s (HTTP %s)\n' "$GREEN" "$NC" "$sport" "$code"
            printf '\n%sВсё в порядке.%s Если открываете https://%s напрямую в браузере —\n' "$GREEN" "$NC" "$DOMAIN"
            printf 'помните: в режиме reality 443 держит Xray, а не nginx. Сайт виден\n'
            printf 'только через рукопожатие Reality (dest 127.0.0.1:%s).\n' "$sport"
        else
            printf '%s✗%s Сайт на 127.0.0.1:%s не ответил (код %s)\n' "$RED" "$NC" "$sport" "$code"
            printf '  journalctl -u nginx -n 30 --no-pager\n'
        fi
    fi
    printf '\n'
    exit 0
}

# ---------------------------------------------------------------------
#  Удаление (--uninstall)
# ---------------------------------------------------------------------
do_uninstall() {
    [[ -n $DOMAIN ]] || ask DOMAIN "Домен для удаления: " ""
    DOMAIN=$(normalize_domain "$DOMAIN")
    valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"
    init_nginx_paths

    confirm "Удалить сайт и конфиг nginx для $DOMAIN? [y/N]: " n || { note "Отменено."; exit 0; }

    backup_file "$NGINX_CONF_FILE"
    rm -f "$NGINX_CONF_LINK" "$NGINX_CONF_FILE" "$NGINX_ENABLED/sni.conf" 2>/dev/null
    rm -rf "$(site_dir)" 2>/dev/null
    rm -f /etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh 2>/dev/null
    systemctl reload nginx 2>/dev/null || true
    ok "Конфиг и файлы сайта удалены (бэкап в $BACKUP_DIR)"

    if confirm "Удалить также сертификат Let's Encrypt для $DOMAIN? [y/N]: " n; then
        certbot delete --cert-name "$DOMAIN" --non-interactive 2>>"$LOG_FILE" && ok "Сертификат удалён" || warn "Не удалось удалить сертификат (возможно, его нет)"
    fi
    exit 0
}

list_themes() {
    printf '\n%sДоступные тематики генератора (-t <имя>):%s\n\n' "$BOLD" "$NC"
    local t
    for t in "${THEMES[@]}"; do
        printf '  %-14s %s\n' "$t" "${THEME_RU[$t]}"
    done
    printf '\n  %-14s %s\n' "random" "случайная тематика (по умолчанию)"
    printf '  %-14s %s\n' "github" "случайный готовый шаблон с GitHub"
    printf '  %-14s %s\n\n' "keep" "оставить текущий сайт"
    exit 0
}

# ---------------------------------------------------------------------
#  Сбор параметров интерактивно
# ---------------------------------------------------------------------
collect_params() {
    # Домен
    if [[ -z $DOMAIN ]]; then
        ask DOMAIN "Введите доменное имя: " ""
    fi
    DOMAIN=$(normalize_domain "$DOMAIN")
    [[ -n $DOMAIN ]] || die "Доменное имя не может быть пустым"
    valid_domain "$DOMAIN" || die "Некорректное доменное имя: $DOMAIN" \
        "Пример: de.example.com (без http:// и без пробелов)"

    # Порт
    if [[ -z $SPORT ]]; then
        ask SPORT "Внутренний порт для Reality (Enter — $DEFAULT_PORT): " "$DEFAULT_PORT"
    fi
    SPORT=${SPORT:-$DEFAULT_PORT}
    valid_port "$SPORT" || die "Некорректный порт: $SPORT" "Допустимо 1–65535, кроме 80 и 443"

    # Режим
    if [[ -z $MODE ]]; then
        MODE=reality
    fi
    [[ $MODE == reality || $MODE == direct ]] || die "Неизвестный режим: $MODE" "Допустимо: reality или direct"

    # Шаблон — проверяем сразу, чтобы не выпускать сертификат при опечатке
    [[ -z $TEMPLATE ]] && TEMPLATE=random
    case $TEMPLATE in
        random | github | keep | /*) : ;;
        *)
            local t known=0
            for t in "${THEMES[@]}"; do [[ $t == "$TEMPLATE" ]] && known=1; done
            ((known)) || die "Неизвестный шаблон/тематика: $TEMPLATE" \
                "Список тематик: bash fakesite.sh --themes" \
                "Или укажите: random, github, keep, либо путь /путь/к/сайту"
            ;;
    esac
    [[ $TEMPLATE == /* && ! -f "$TEMPLATE/index.html" ]] &&
        die "В папке $TEMPLATE нет index.html"

    # Email
    if [[ -n $EMAIL ]] && ! valid_email "$EMAIL"; then
        die "Некорректный e-mail: $EMAIL"
    fi

    ok "Параметры приняты: $DOMAIN, порт $SPORT, режим $MODE, шаблон $TEMPLATE"
}

# ---------------------------------------------------------------------
#  Основной поток установки
# ---------------------------------------------------------------------
run_install() {
    collect_params
    init_nginx_paths

    install_packages
    check_dns
    check_ports
    check_firewall

    # 1) сначала поднимаем nginx только для ACME (порт 80) и выпускаем сертификат
    backup_file "$NGINX_CONF_FILE"
    write_acme_only_conf
    obtain_cert
    setup_renewal

    # 2) кладём сайт
    deploy_content

    # 3) финальный конфиг с TLS-эндпоинтом (loopback для reality / 443 для direct)
    step "Создание итоговой конфигурации Nginx..."
    write_final_conf
    ok "Конфигурация Nginx создана и применена"

    # 4) самопроверка
    verify_site

    print_summary
}

# ---------------------------------------------------------------------
main() {
    parse_args "$@"

    # Справочное действие — без root и без баннера
    [[ $ACTION == themes ]] && list_themes

    clear 2>/dev/null || true
    printf '%s%s=====================================================%s\n' "$BOLD" "$CYAN" "$NC"
    printf '%s%s  Self SNI Scripts by begugla  ·  v%s%s\n' "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$NC"
    printf '%s%s=====================================================%s\n\n' "$BOLD" "$CYAN" "$NC"
    log "Запуск v$SCRIPT_VERSION, действие: $ACTION, аргументы: $*"

    check_root
    check_os

    case $ACTION in
        check)     do_check ;;
        uninstall) do_uninstall ;;
        install)   run_install ;;
    esac
}

main "$@"
