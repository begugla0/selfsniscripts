#!/usr/bin/env bash
# =====================================================================
#  Self SNI Scripts by begugla — удаление (remove.sh)
#  Снимает сайт-маскировку, конфиг nginx и (по желанию) сертификат,
#  возвращая nginx в рабочее состояние.
#  https://github.com/begugla0/selfsniscripts
#
#  Запуск:
#    bash <(curl -Ls https://raw.githubusercontent.com/begugla0/selfsniscripts/main/remove.sh)
#
#  Справка:  bash remove.sh --help
# =====================================================================

set -o pipefail
umask 022

SCRIPT_VERSION="2.0.0"
REPO_URL="https://github.com/begugla0/selfsniscripts"
SITES_ROOT="/var/www/selfsni"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
BACKUP_DIR="/root/selfsni-backup"
LOG_FILE="/tmp/sni_remove_$(date +%Y%m%d_%H%M%S).log"

DOMAIN=""
REMOVE_ALL=0
WITH_CERT=""      # "", yes, no
KEEP_BACKUP=1
ASSUME_YES=0

# ---------------------------------------------------------------------
#  Оформление
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; NC=""
fi

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
run()  { log "\$ $*"; "$@" >>"$LOG_FILE" 2>&1; local rc=$?; ((rc != 0)) && log "(код: $rc)"; return $rc; }
ok()   { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; log "OK: $*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; log "WARN: $*"; }
note() { printf '     %s\n' "$*"; }
hint() { printf '     %s%s%s\n' "$YELLOW" "$*" "$NC"; }

die() {
    printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1"
    log "ERROR: $1"
    shift
    local h; for h in "$@"; do hint "$h"; done
    printf '     %sПодробнее: %s%s\n' "$YELLOW" "$REPO_URL" "$NC"
    exit 1
}

trap 'printf "\n%sПрервано пользователем.%s\n" "$RED" "$NC"; exit 130' INT TERM

has_tty() { { : </dev/tty; } 2>/dev/null; }

# confirm "вопрос [y/N]: " n|y
confirm() {
    local ans def=${2:-n}
    if ((ASSUME_YES)) || ! has_tty; then [[ $def == y ]]; return; fi
    read -r -p "$1" ans </dev/tty || true
    ans=${ans:-$def}; ans=${ans,,}
    [[ $ans == y* || $ans == д* ]]
}

# ---------------------------------------------------------------------
#  Справка и аргументы
# ---------------------------------------------------------------------
usage() {
    cat <<EOF
Self SNI Scripts v$SCRIPT_VERSION — удаление сайта-маскировки

Использование: bash remove.sh [параметры]

  -d, --domain DOMAIN   домен, который нужно удалить
      --all             удалить все сайты-маски, созданные скриптом
      --with-cert       удалить также сертификат Let's Encrypt
      --keep-cert       НЕ удалять сертификат (по умолчанию спрашивает)
      --no-backup       не сохранять бэкап конфига перед удалением
  -y, --yes             без вопросов (нужен -d или --all)
  -h, --help            эта справка

Примеры:
  bash remove.sh                         # покажет список и спросит, что удалить
  bash remove.sh -d de.example.com
  bash remove.sh -d de.example.com --with-cert -y
  bash remove.sh --all --keep-cert -y
EOF
}

need_arg() { [[ -n ${2:-} && ${2:0:1} != "-" ]] || die "Параметру $1 нужно значение"; }

parse_args() {
    while (($#)); do
        [[ $1 == --*=* ]] && set -- "${1%%=*}" "${1#*=}" "${@:2}"
        case $1 in
            -d|--domain) need_arg "$1" "${2:-}"; DOMAIN=$2; shift 2 ;;
            --all)       REMOVE_ALL=1; shift ;;
            --with-cert) WITH_CERT=yes; shift ;;
            --keep-cert) WITH_CERT=no; shift ;;
            --no-backup) KEEP_BACKUP=0; shift ;;
            -y|--yes)    ASSUME_YES=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *) die "Неизвестный параметр: $1" "Справка: bash remove.sh --help" ;;
        esac
    done
}

check_root() { ((EUID == 0)) || die "Скрипт нужно запускать от root" "Выполните: sudo -i, затем запустите снова"; }

normalize_domain() {
    local d=${1,,}; d=${d//[[:space:]]/}; d=${d#http://}; d=${d#https://}
    d=${d%%/*}; d=${d%%:*}; d=${d%.}; printf '%s' "$d"
}

# ---------------------------------------------------------------------
#  Поиск установленных сайтов-масок
# ---------------------------------------------------------------------
# Печатает список доменов (по одному в строке), найденных по конфигам selfsni
find_installs() {
    local f dom
    # новые конфиги: selfsni-<домен>.conf
    for f in "$NGINX_AVAIL"/selfsni-*.conf "$NGINX_ENABLED"/selfsni-*.conf; do
        [[ -e $f ]] || continue
        dom=$(basename "$f"); dom=${dom#selfsni-}; dom=${dom%.conf}
        printf '%s\n' "$dom"
    done
    # старый конфиг прошлых версий: sni.conf — вытащим server_name
    for f in "$NGINX_ENABLED"/sni.conf "$NGINX_AVAIL"/sni.conf; do
        [[ -e $f ]] || continue
        dom=$(grep -m1 -oE 'server_name[[:space:]]+[^;]+' "$f" | awk '{print $2}')
        [[ -n $dom ]] && printf '%s\n' "$dom"
    done
    # а также по папкам сайтов
    if [[ -d $SITES_ROOT ]]; then
        for f in "$SITES_ROOT"/*/; do
            [[ -d $f ]] || continue
            dom=$(basename "$f"); printf '%s\n' "$dom"
        done
    fi
}

list_installs_unique() { find_installs | grep -v '^$' | sort -u; }

backup_file() {
    local f=$1
    ((KEEP_BACKUP)) || return 0
    [[ -e $f ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s).bak" 2>/dev/null &&
        log "бэкап: $f → $BACKUP_DIR" || true
}

cert_exists() { [[ -d "/etc/letsencrypt/live/$1" ]]; }

# ---------------------------------------------------------------------
#  Удаление одного домена
# ---------------------------------------------------------------------
remove_one() {
    local dom=$1
    printf '\n%s── Удаление %s ──%s\n' "$BOLD" "$dom" "$NC"
    log "=== remove $dom"

    local conf_avail="$NGINX_AVAIL/selfsni-$dom.conf"
    local conf_link="$NGINX_ENABLED/selfsni-$dom.conf"
    local removed_any=0

    # конфиги
    local f
    for f in "$conf_link" "$conf_avail"; do
        if [[ -e $f || -L $f ]]; then
            backup_file "$f"
            run rm -f "$f" && { ok "Удалён $f"; removed_any=1; }
        fi
    done

    # старый общий конфиг sni.conf — удаляем, только если он про этот домен
    for f in "$NGINX_ENABLED/sni.conf" "$NGINX_AVAIL/sni.conf"; do
        [[ -e $f ]] || continue
        if grep -qE "server_name[[:space:]]+$dom([[:space:]]|;)" "$f" 2>/dev/null; then
            backup_file "$f"
            run rm -f "$f" && { ok "Удалён старый конфиг $f"; removed_any=1; }
        fi
    done

    # файлы сайта
    local dir="$SITES_ROOT/$dom"
    if [[ -d $dir ]]; then
        run rm -rf "$dir" && { ok "Удалены файлы сайта $dir"; removed_any=1; }
    fi

    ((removed_any)) || warn "Для $dom не нашлось ни конфига, ни файлов сайта"

    # сертификат
    local do_cert=$WITH_CERT
    if cert_exists "$dom"; then
        if [[ -z $do_cert ]]; then
            if confirm "     Удалить также сертификат Let's Encrypt для $dom? [y/N]: " n; then
                do_cert=yes
            else
                do_cert=no
            fi
        fi
        if [[ $do_cert == yes ]]; then
            if command -v certbot >/dev/null 2>&1; then
                run certbot delete --cert-name "$dom" --non-interactive &&
                    ok "Сертификат $dom удалён" ||
                    warn "Не удалось удалить сертификат $dom (возможно, имя cert-name другое)"
            else
                warn "certbot не найден — сертификат не удалён"
            fi
        else
            note "Сертификат $dom оставлен (/etc/letsencrypt/live/$dom/)"
        fi
    fi
}

# Если не осталось ни одного сайта-маски — убрать общий renewal-hook
cleanup_global() {
    local left
    left=$(list_installs_unique)
    if [[ -z $left ]]; then
        [[ -f /etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh ]] &&
            run rm -f /etc/letsencrypt/renewal-hooks/deploy/00-reload-nginx.sh &&
            log "удалён deploy-hook"
        [[ -f /etc/cron.d/selfsni-certbot ]] &&
            run rm -f /etc/cron.d/selfsni-certbot && log "удалён cron selfsni-certbot"
        # пустой каталог сайтов
        [[ -d $SITES_ROOT ]] && rmdir "$SITES_ROOT" 2>/dev/null
    fi
    :
}

reload_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        warn "nginx не установлен — перезагрузка не требуется"
        return 0
    fi
    # вернуть дефолтный сайт, если не осталось вообще ни одного конфига
    if ! ls "$NGINX_ENABLED"/*.conf >/dev/null 2>&1 && [[ ! -e "$NGINX_ENABLED/default" ]]; then
        if [[ -e "$NGINX_AVAIL/default" ]]; then
            ln -sf "$NGINX_AVAIL/default" "$NGINX_ENABLED/default"
            log "восстановлен дефолтный сайт nginx"
        fi
    fi
    if run nginx -t; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            run systemctl reload nginx || run systemctl restart nginx || warn "Не удалось перезагрузить nginx"
        fi
        ok "Конфигурация nginx валидна, изменения применены"
    else
        warn "nginx -t сообщает об ошибке — проверьте вручную: nginx -t"
    fi
}

# ---------------------------------------------------------------------
#  Выбор, что удалять
# ---------------------------------------------------------------------
choose_targets() {
    local -n _out=$1
    local installs
    mapfile -t installs < <(list_installs_unique)

    if ((REMOVE_ALL)); then
        ((${#installs[@]})) || die "Не найдено ни одного сайта-маски, созданного скриптом"
        _out=("${installs[@]}")
        return 0
    fi

    if [[ -n $DOMAIN ]]; then
        DOMAIN=$(normalize_domain "$DOMAIN")
        _out=("$DOMAIN")
        return 0
    fi

    # интерактивный выбор
    if ((${#installs[@]} == 0)); then
        die "Не найдено установок Self SNI" \
            "Если сайт ставился вручную/старой версией — укажите домен: bash remove.sh -d домен"
    fi

    printf '\n%sНайденные сайты-маски:%s\n\n' "$BOLD" "$NC"
    local i
    for i in "${!installs[@]}"; do
        local d=${installs[i]} c=""
        cert_exists "$d" && c=" ${GREEN}(есть сертификат)${NC}"
        printf '  %s%d%s) %s%s\n' "$CYAN" "$((i + 1))" "$NC" "$d" "$c"
    done
    printf '  %sa%s) удалить все\n' "$CYAN" "$NC"
    printf '  %sq%s) выйти\n\n' "$CYAN" "$NC"

    if ! has_tty; then
        die "Нет интерактивного терминала" "Укажите домен явно: bash remove.sh -d домен, или --all"
    fi

    local pick
    read -r -p "Что удалить? (номер / a / q): " pick </dev/tty || pick=q
    case ${pick,,} in
        q|"") note "Отменено."; exit 0 ;;
        a)    _out=("${installs[@]}") ;;
        *)
            [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#installs[@]})) ||
                die "Неверный выбор: $pick"
            _out=("${installs[pick - 1]}")
            ;;
    esac
}

# ---------------------------------------------------------------------
main() {
    parse_args "$@"
    clear 2>/dev/null || true
    printf '%s%s=====================================================%s\n' "$BOLD" "$CYAN" "$NC"
    printf '%s%s  Self SNI Scripts — удаление  ·  v%s%s\n' "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$NC"
    printf '%s%s=====================================================%s\n' "$BOLD" "$CYAN" "$NC"
    log "Запуск remove v$SCRIPT_VERSION, аргументы: $*"

    check_root

    local targets=()
    choose_targets targets

    # подтверждение
    printf '\n%sБудут удалены сайты-маски:%s %s\n' "$YELLOW" "$NC" "${targets[*]}"
    [[ $WITH_CERT == yes ]] && printf '%sВместе с сертификатами Let'\''s Encrypt.%s\n' "$YELLOW" "$NC"
    if ! confirm "Продолжить удаление? [y/N]: " "$([[ $ASSUME_YES -eq 1 ]] && echo y || echo n)"; then
        note "Отменено."
        exit 0
    fi

    local d
    for d in "${targets[@]}"; do
        remove_one "$d"
    done

    cleanup_global
    reload_nginx

    printf '\n%s=====================================================%s\n' "$CYAN" "$NC"
    printf '%sУдаление завершено.%s\n' "$GREEN" "$NC"
    ((KEEP_BACKUP)) && [[ -d $BACKUP_DIR ]] && note "Бэкапы конфигов: $BACKUP_DIR"
    note "Лог: $LOG_FILE"
    printf '%s=====================================================%s\n' "$CYAN" "$NC"
}

main "$@"
