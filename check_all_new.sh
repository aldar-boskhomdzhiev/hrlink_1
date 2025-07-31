#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

clr_rst='\033[0m'
clr_red='\033[1;31m'
clr_grn='\033[1;32m'
clr_ylw='\033[1;33m'

log() {
    printf "$1$2$clr_rst\n"
}

initial_checks() {
    uuidgen > /dev/null || { echo "uuidgen не найден. для работы скрипта необходимо установить uuidgen"; exit 3; }

    ls docker-compose.yaml > /dev/null || { echo "скрипт нужно запустить из директории с docker-compose.yaml"; exit 4; }
    [[ $(ls .env) ]] || { echo "скрипт нужно запустить из директории с docker-compose.yaml и .env/backend.env"; exit 4; }

    set +u
    ########## Даты и валидация дат
    start_date=$1
    end_date=$2

    # дефолтные значения датам - последние 7 дней
    if [[ -z $start_date ]]; then
        start_date=$(date -d "-7 days" +"%Y-%m-%d")
    fi
    if [[ -z $end_date ]]; then
        end_date=$(date +"%Y-%m-%d")
    fi

    echo "$start_date" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' && echo "$end_date" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo "Дата не соответствует формату YYYY-MM-DD"; exit 2; }

    start_timestamp=$(date -d "$start_date" +%s)
    end_timestamp=$(date -d "$end_date" +%s)

    if [[ $start_timestamp -gt $end_timestamp ]]; then
        log $clr_red "Вторая дата должна быть больше первой"
    fi

    set -u

    set +e
    ##### uuid для уникальности имен директорий и архива + название домена
    uuid_name="$(uuidgen)"
    source .env
    archive_name="check-all_${CLIENT_DOMAIN}_${start_date}_${end_date}_${uuid_name}"
    set -e

    ROOT_DIR="/tmp/$archive_name"
    mkdir -p $ROOT_DIR
    log "" "Рабочая директория: $ROOT_DIR"
}

app_configs() {
    log "$clr_ylw" "Сбор конфигов приложения"

    local WORK_DIR="$ROOT_DIR/config"
    mkdir "$WORK_DIR"

    ########## конфиги
    cp -r ekd-config/*.conf "$WORK_DIR"
    mkdir "$WORK_DIR/ekd-file"
    cp -r ekd-config/ekd-file/*.conf "$WORK_DIR/ekd-file"
    cp docker-compose.yaml nginx.conf "$WORK_DIR"
    rsync -a --exclude="*.env" .backup "$WORK_DIR"

    ########### конфиги postgresql
    docker cp ekd-postgresql:/var/lib/postgresql/data/pgdata/postgresql.conf "$WORK_DIR" 1>/dev/null
    docker cp ekd-postgresql:/var/lib/postgresql/data/pgdata/pg_hba.conf "$WORK_DIR" 1>/dev/null
}

cloud_availability() {
    log "$clr_ylw" "Проверка доступности HRlink Cloud"

    local WORK_DIR="$ROOT_DIR/check_urls"
    mkdir "$WORK_DIR"

    ########## доступы по адресам
    urls=(
        "https://license.hr-link.ru/api/v1/version"
        "https://zorro.hr-link.ru/actuator/info"
        "https://pechkin.hr-link.ru/api/v1/version"
        "https://pinboard.hr-link.ru/api/v1/version"
        "https://hrlk.ru/api/v1/version"
        "https://esa.hr-link.ru/api/v1/version"
        "https://kronos.hr-link.ru/api/v1/version"
    )

    set +e
    for url in "${urls[@]}"; do
        hostname=$(echo "$url" | awk -F '/' '{print $3}' | awk -F '.' '{print $1}')
        dir="$WORK_DIR/$hostname"
        mkdir "$dir"
        timeout 5 curl -vvvv "$url" > "$dir/$hostname-host.txt" 2>&1
        timeout 5 docker exec ekd-ui curl -vvvv "$url" > "$dir/$hostname-ekd-ui.txt" 2>&1
        timeout 5 docker exec ekd-monolith curl -vvvv "$url" > "$dir/$hostname-ekd-monolith.txt" 2>&1
        timeout 5 docker exec ekd-file-processing curl -vvvv "$url" > "$dir/$hostname-ekd-file-processing.txt" 2>&1
        timeout 5 docker exec ekd-calendar curl -vvvv "$url" > "$dir/$hostname-ekd-calendar.txt" 2>&1
    done

    timeout 5 curl -vvvv -I https://docker.hr-link.ru > "$WORK_DIR/docker.txt" 2>&1
    set -e
}

container_info() {
    log "$clr_ylw" "Сбор информации о контейнерах"

    local WORK_DIR="$ROOT_DIR/dockers"
    mkdir "$WORK_DIR"
    ############ инспекты контейнеров
    docker ps -a > "$WORK_DIR/docker_ps.txt"
    docker ps -a --format "{{.Names}}" | while read -r container_name; do
        docker inspect "$container_name" > "$WORK_DIR/inspect_$container_name.txt" 2>&1
    done
    docker stats -a --no-stream >> "$WORK_DIR/docker_stats.txt" 2>&1
    #################################
}

container_logs() {
    log "$clr_ylw" "Сбор логов контейнеров"

    local WORK_DIR="$ROOT_DIR/logs"
    mkdir "$WORK_DIR"

    ############ логи контейнеров
    set +u
    declare -A log_dirs=(
        ["monolith"]="ekd-monolith"
        ["file"]="ekd-file"
        ["calendar"]="ekd-calendar"
        ["chat"]="ekd-chat"
        ["repeat_notification"]="ekd-repeat-notification"
        ["showcase"]="ekd-showcase"
        ["file_processing"]="ekd-file-processing"
        ["api_gateway"]="ekd-api-gateway"
    )
    # эта штука ↑↓ динамически задает переменные с директориями логов контейнеров
    for key in "${!log_dirs[@]}"; do
        if ls "logs/${log_dirs[$key]}" &>/dev/null; then
            eval "ekd_${key}_logs=\"./logs/${log_dirs[$key]}\""
        else
            eval "ekd_${key}_logs=\"./${log_dirs[$key]}-logs\""
        fi
    done
    set -u

    mkdir -p $WORK_DIR/ekd_{monolith,file,calendar,chat,repeat_notification,showcase,file_processing,api_gateway}

    for key in "${!log_dirs[@]}"; do
        log_var="ekd_${key}_logs"
        if [[ -n "${!log_var}" ]]; then
            cp "${!log_var}/application.log" "$WORK_DIR/ekd_$key/"
            rsync -a --exclude '*application*' --exclude '*lifecycle*' --exclude '*java_crashes*' "${!log_var}/" "$WORK_DIR/ekd_$key"
        fi
    done

    flag_date=$start_date
    while [ "$flag_date" != "$end_date" ]; do
        for key in "${!log_dirs[@]}"; do
            log_var="ekd_${key}_logs"
            if [ -n "$(ls -A "${!log_var}"/application-log-"$flag_date"* 2>/dev/null)" ]; then
                cp "${!log_var}"/application-log-"$flag_date"* "$WORK_DIR/ekd_$key/" >/dev/null 2>&1
            fi
        done
        flag_date=$(date -I -d "$flag_date + 1 day")
    done

    mkdir "$WORK_DIR/ekd_kafka"

    set +e
    cp ekd_kafka/logs/*.log "$WORK_DIR/ekd_kafka"
    docker logs ekd_kafka --since "$start_date" --until "$end_date" > "$WORK_DIR/ekd_kafka/docker_logs.log"

    cp -r logs/updates "$WORK_DIR"
    set -e
}

sys_info() {
    log "$clr_ylw" "Сбор информации о системе"

    local WORK_DIR="$ROOT_DIR/sys"
    mkdir "$WORK_DIR"

    ########## 10 процессов по cpu и mem
    ps aux --sort=-%mem | head -n 11 > "$WORK_DIR/top_10_mem.txt"
    ps aux --sort=-%cpu | head -n 11 > "$WORK_DIR/top_10_cpu.txt"
    ####################################

    ########## инфа о системе
    lsblk -e 7 > "$WORK_DIR/disk_lsblk.txt"
    df -h > "$WORK_DIR/disk_df.txt"

    lscpu > "$WORK_DIR/lscpu.txt"
    lsmem > "$WORK_DIR/lsmem.txt"
    swapon --show > "$WORK_DIR/lsswap.txt"

    cat /etc/os-release > "$WORK_DIR/os-release.txt"
}

nginx_logs() {
    log "$clr_ylw" "Сбор логов nginx ekd-ui"

    local WORK_DIR="$ROOT_DIR/nginx_log"
    mkdir "$WORK_DIR"

    ########### логи nginx
    docker logs ekd-ui --since "$start_date" --until "$end_date" > "$WORK_DIR/nginx.log"
}

cert_info() {
    log "$clr_ylw" "Сбор SSL сертификатов приложения"

    local WORK_DIR="$ROOT_DIR/ssl_certs"
    mkdir "$WORK_DIR"
    ########### сертификаты
    cp -r certs/* "$WORK_DIR"
}

archive_all() {
    log "$clr_ylw" "Архивация"
    tar czf "/tmp/$archive_name.tar.gz" -C "/tmp" "$archive_name"
    log $clr_grn "Готово! Архив расположен по пути /tmp/$archive_name.tar.gz"
    rm -rf "$ROOT_DIR"
}

initial_checks
app_configs
cloud_availability
container_info
container_logs
sys_info
nginx_logs
cert_info
archive_all
