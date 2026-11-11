#!/usr/bin/env bash
#
# check_api.sh - checks API availability by HTTP status code.
#
# Usage:  ./check_api.sh [-t SECONDS] [-v] URL
# Exit:   0 if the server answered 200, 1 in any other case.

set -o nounset
set -o pipefail

readonly EXPECTED_STATUS=200

timeout=10
verbose=0

usage() {
    cat <<EOF
Использование: ${0##*/} [-t СЕКУНДЫ] [-v] URL

Отправляет HTTP-запрос на URL и проверяет,
что сервер ответил кодом ${EXPECTED_STATUS}.

Ключи:
  -t СЕКУНДЫ  таймаут запроса, по умолчанию ${timeout}
  -v          дополнительно вывести URL и время ответа
  -h          показать эту справку

Коды возврата: 0 - API доступен, 1 - API недоступен или ошибка запуска.
EOF
}

error() {
    printf 'Ошибка: %s\n' "$*" >&2
}

# Short explanation for the most common curl failures
curl_reason() {
    case $1 in
        6)  echo "не удалось определить адрес хоста" ;;
        7)  echo "не удалось подключиться к серверу" ;;
        28) echo "превышено время ожидания ответа" ;;
        35|60) echo "ошибка TLS-соединения" ;;
        *)  echo "curl завершился с кодом $1" ;;
    esac
}

while getopts ':t:vh' opt; do
    case $opt in
        t) timeout=$OPTARG ;;
        v) verbose=1 ;;
        h) usage; exit 0 ;;
        :) error "для ключа -$OPTARG нужно значение"; exit 1 ;;
        *) error "неизвестный ключ -$OPTARG"; usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if (( $# != 1 )); then
    error "нужно передать один аргумент: URL API"
    usage >&2
    exit 1
fi

url=$1

if ! [[ $timeout =~ ^[1-9][0-9]*$ ]]; then
    error "таймаут должен быть целым положительным числом: $timeout"
    exit 1
fi

# http(s)://host[:port][/path], host is letters, digits, dots and hyphens
scheme_re='https?://'
host_re='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?'
port_re='(:[0-9]{1,5})?'
path_re='(/[^[:space:]]*)?'
url_regex="^${scheme_re}${host_re}${port_re}${path_re}\$"

if ! [[ $url =~ $url_regex ]]; then
    error "некорректный URL: $url (нужен http:// или https://)"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    error "не найден curl"
    exit 1
fi

# Response body is not needed, only the status code and the total time.
# If the request fails, curl still prints 000 as the status code.
curl_exit=0
response=$(curl --silent --output /dev/null --max-time "$timeout" \
    --write-out '%{http_code} %{time_total}' "$url") || curl_exit=$?
read -r status time_total <<< "$response"

if [[ $status == "$EXPECTED_STATUS" ]]; then
    echo "API доступен"
    rc=0
else
    echo "API недоступен, код ответа: $status"
    rc=1
fi

if (( curl_exit != 0 )); then
    echo "Причина: $(curl_reason "$curl_exit")" >&2
fi

if (( verbose )); then
    echo "URL: $url"
    echo "Время ответа: ${time_total} с"
fi

exit "$rc"
