#!/usr/bin/env bash
#
# analyze_logs.sh - generates a test access.log and prints statistics for it.
#
# Usage:  ./analyze_logs.sh [-n LINES] [-f FILE] [-s SEED] [-a] [-h]

set -euo pipefail

readonly MIN_LINES=300

lines=500
log_file=access.log
seed=2026
analyze_only=0

# IPv4 address: four groups of 1-3 digits separated by dots.
# Groups above 255 are filtered out later with awk.
readonly IP_REGEX='([0-9]{1,3}\.){3}[0-9]{1,3}'

# Full log line: IP - - [date] "METHOD /path HTTP/x.x" CODE
readonly DATE_REGEX='\[[^]]+\]'
readonly REQ_REGEX='"[A-Z]+ [^ "]+ HTTP/[0-9.]+"'
readonly LINE_REGEX="^${IP_REGEX} - - ${DATE_REGEX} ${REQ_REGEX} [0-9]{3}\$"

# Test data in "value:weight" form, a bigger weight means the value
# shows up in the log more often
readonly CLIENT_IPS=(
    "192.168.1.25:9" "10.0.0.5:7" "172.16.5.4:6" "192.168.1.10:4"
    "10.0.0.12:3" "192.168.1.33:2" "203.0.113.45:2" "198.51.100.7:1"
)
readonly REQUESTS=(
    "GET /api/users:10" "GET /api/users/{id}:8" "GET /api/products:8"
    "GET /api/products/{id}:6" "POST /api/login:7" "POST /api/orders:4"
    "PUT /api/users/{id}:2" "DELETE /api/orders/{id}:2" "GET /health:3"
)
readonly STATUSES=(
    "200:62" "304:4" "400:4" "401:3" "403:2" "404:9"
    "500:4" "502:2" "503:3"
)

usage() {
    cat <<EOF
Использование: ${0##*/} [-n СТРОК] [-f ФАЙЛ] [-s ЧИСЛО] [-a] [-h]

Генерирует тестовый лог веб-сервера и выводит статистику по нему:
число запросов, топ-3 IP-адресов, число ответов с кодами 4xx и 5xx.

Ключи:
  -n СТРОК  число строк в логе: от ${MIN_LINES}, по умолчанию ${lines}
  -f ФАЙЛ   файл лога, по умолчанию ${log_file}
  -s ЧИСЛО  зерно генератора случайных чисел, по умолчанию ${seed}
  -a        не генерировать лог, только проанализировать существующий файл
  -h        показать эту справку
EOF
}

fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

# Linear congruential generator. Bash's own RANDOM may differ between
# versions, this one gives the same log on any machine for the same seed.
rand_state=0
next_random() {
    rand_state=$(( (rand_state * 1103515245 + 12345) % 2147483648 ))
    REPLY=$(( rand_state / 65536 % $1 ))
}

# Expands "value:weight" pairs into an array where each value
# is repeated weight times. Usage: make_pool ARRAY_NAME PAIR...
make_pool() {
    local -n pool=$1
    shift
    local pair value weight
    pool=()
    for pair in "$@"; do
        value=${pair%:*}
        weight=${pair##*:}
        while (( weight-- > 0 )); do
            pool+=("$value")
        done
    done
}

generate_log() {
    local file=$1 count=$2
    local -a ip_pool request_pool status_pool
    local i ip request status id
    local placeholder='{id}'
    local sec=$(( 10 * 3600 + 15 * 60 + 32 ))   # first record at 10:15:32

    make_pool ip_pool "${CLIENT_IPS[@]}"
    make_pool request_pool "${REQUESTS[@]}"
    make_pool status_pool "${STATUSES[@]}"
    rand_state=$(( 10#$seed ))

    for (( i = 0; i < count; i++ )); do
        next_random "${#ip_pool[@]}"
        ip=${ip_pool[REPLY]}

        next_random "${#request_pool[@]}"
        request=${request_pool[REPLY]}
        if [[ $request == *"$placeholder"* ]]; then
            next_random 500
            id=$(( REPLY + 1 ))
            request=${request/"$placeholder"/$id}
        fi

        # Login fails with 401 in about a third of attempts,
        # successful POST and DELETE get 201 and 204
        if [[ $request == "POST /api/login" ]]; then
            next_random 3
            status=$(( REPLY == 0 ? 401 : 200 ))
        else
            next_random "${#status_pool[@]}"
            status=${status_pool[REPLY]}
            if [[ $status == 200 && $request == POST* ]]; then
                status=201
            elif [[ $status == 200 && $request == DELETE* ]]; then
                status=204
            fi
        fi

        printf '%s - - [15/Aug/2026:%02d:%02d:%02d] "%s HTTP/1.1" %s\n' \
            "$ip" $(( sec / 3600 % 24 )) $(( sec / 60 % 60 )) $(( sec % 60 )) \
            "$request" "$status"

        next_random 4
        sec=$(( sec + REPLY ))
    done > "$file"
}

analyze_log() {
    local file=$1
    local total_lines requests bad_lines errors_4xx errors_5xx

    total_lines=$(wc -l < "$file")
    requests=$(grep -cE "$LINE_REGEX" "$file" || true)
    bad_lines=$(( total_lines - requests ))

    echo "===== Статистика по файлу ${file} ====="
    echo "Общее количество запросов: ${requests}"
    if (( bad_lines > 0 )); then
        echo "Пропущено строк в неверном формате: ${bad_lines}"
    fi
    echo

    echo "Топ-3 IP-адресов по числу запросов:"
    grep -oE "^${IP_REGEX}" "$file" |
        awk -F. '$1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255' |
        sort | uniq -c | sort -k1,1nr -k2,2 |
        awk 'NR <= 3 { printf "  %d) %-15s %5d\n", NR, $2, $1 }'
    echo

    # Status code is the last field of the line
    read -r errors_4xx errors_5xx < <(
        awk '$NF ~ /^4[0-9][0-9]$/ { c4++ }
             $NF ~ /^5[0-9][0-9]$/ { c5++ }
             END { print c4 + 0, c5 + 0 }' "$file"
    )
    awk -v c4="$errors_4xx" -v c5="$errors_5xx" -v total="$requests" 'BEGIN {
        if (total == 0) total = 1
        printf "Ответы с кодами 4xx: %d (%.1f%%)\n", c4, c4 * 100 / total
        printf "Ответы с кодами 5xx: %d (%.1f%%)\n", c5, c5 * 100 / total
    }'
    echo

    echo "Распределение по кодам ответа:"
    awk '$NF ~ /^[1-5][0-9][0-9]$/ { print $NF }' "$file" |
        sort | uniq -c |
        awk '{ printf "  %s  %5d\n", $2, $1 }'
    echo

    # Numeric ids are replaced with {id}, so /api/users/7 and
    # /api/users/42 are counted as one endpoint
    echo "Самые популярные эндпоинты:"
    sed -nE 's/^[^"]*"[A-Z]+ ([^ "?]+)[^"]*".*$/\1/p' "$file" |
        sed -E 's#/[0-9]+$#/{id}#' |
        sort | uniq -c | sort -k1,1nr -k2,2 |
        awk 'NR <= 3 { printf "  %-22s %5d\n", $2, $1 }'
}

while getopts ':n:f:s:ah' opt; do
    case $opt in
        n) lines=$OPTARG ;;
        f) log_file=$OPTARG ;;
        s) seed=$OPTARG ;;
        a) analyze_only=1 ;;
        h) usage; exit 0 ;;
        :) fail "для ключа -$OPTARG нужно значение" ;;
        *) echo "Ошибка: неизвестный ключ -$OPTARG" >&2; usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

(( $# == 0 )) || fail "лишние аргументы: $*"

for tool in grep awk sed sort uniq wc; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найдена утилита $tool"
done

if (( ! analyze_only )); then
    [[ $lines =~ ^[0-9]+$ ]] || fail "число строк должно быть целым: $lines"
    (( 10#$lines >= MIN_LINES )) || fail "нужно не меньше $MIN_LINES строк"
    [[ $seed =~ ^[0-9]+$ ]] || fail "зерно -s должно быть целым: $seed"

    generate_log "$log_file" "$(( 10#$lines ))"
    echo "Сгенерирован файл ${log_file}: $(wc -l < "$log_file") строк"
    echo
fi

[[ -f $log_file ]] || fail "файл $log_file не найден"
[[ -s $log_file ]] || fail "файл $log_file пустой"

analyze_log "$log_file"
