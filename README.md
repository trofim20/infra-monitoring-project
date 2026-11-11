# infra-monitoring-project

[![CI](https://github.com/trofim20/infra-monitoring-project/actions/workflows/ci.yml/badge.svg)](https://github.com/trofim20/infra-monitoring-project/actions/workflows/ci.yml)

Мониторинг простого echo-API: проверка доступности, анализ логов веб-сервера,
стек из API и обратного прокси в Docker Compose и проверки в GitHub Actions.

## Структура проекта

```
.
├── check_api.sh                         проверка доступности API по коду ответа
├── analyze_logs.sh                      генерация и анализ access.log
├── docker-compose.yml                   стек api + proxy
├── nginx/templates/
│   └── default.conf.template            шаблон конфигурации nginx
├── .github/workflows/ci.yml             пайплайн GitHub Actions
├── .gitignore
└── .gitattributes                       окончания строк LF для всех файлов
```

## Что нужно для запуска

- Linux или WSL с bash 4.3 и новее
- curl, grep, awk, sed, sort, uniq (есть в любом дистрибутиве)
- Docker и Docker Compose
- Git

```bash
git clone https://github.com/trofim20/infra-monitoring-project.git
cd infra-monitoring-project
chmod +x check_api.sh analyze_logs.sh
```

## check_api.sh

Проверяет, что API отвечает кодом 200.

```
./check_api.sh [-t СЕКУНДЫ] [-v] URL
```

| Ключ | Что делает |
|------|------------|
| `-t` | таймаут запроса в секундах, по умолчанию 10 |
| `-v` | дополнительно выводит URL и время ответа |
| `-h` | справка |

Сначала URL проверяется регулярным выражением (только `http://` и `https://`),
потом `curl` делает запрос и забирает код ответа через `--write-out`.

| Ситуация | Вывод | Код возврата |
|----------|-------|--------------|
| сервер ответил 200 | `API доступен` | 0 |
| сервер ответил другим кодом | `API недоступен, код ответа: XXX` | 1 |
| сервер не ответил (нет DNS, порт закрыт, таймаут) | `API недоступен, код ответа: 000` и причина в stderr | 1 |
| нет аргумента, лишний аргумент или неверный URL | сообщение об ошибке в stderr | 1 |

```
$ ./check_api.sh https://httpbin.org/status/200
API доступен
$ echo $?
0

$ ./check_api.sh https://httpbin.org/status/404
API недоступен, код ответа: 404
$ echo $?
1
```

## analyze_logs.sh

Генерирует тестовый лог и выводит по нему статистику.

```
./analyze_logs.sh [-n СТРОК] [-f ФАЙЛ] [-s ЧИСЛО] [-a]
```

| Ключ | Что делает | По умолчанию |
|------|------------|--------------|
| `-n` | сколько строк сгенерировать, минимум 300 | 500 |
| `-f` | путь к файлу лога | `access.log` |
| `-s` | начальное значение генератора случайных чисел | 2026 |
| `-a` | не генерировать лог, а проанализировать уже существующий файл | |
| `-h` | справка | |

Строки лога выглядят так:

```
192.168.1.25 - - [15/Aug/2026:10:15:34] "GET /api/users HTTP/1.1" 200
10.0.0.5 - - [15/Aug/2026:10:15:41] "POST /api/login HTTP/1.1" 401
```

Генератор псевдослучайных чисел написан прямо в скрипте (линейный
конгруэнтный), поэтому при одинаковом `-s` лог получается одинаковым на любой машине.

Как считается статистика:

- общее количество запросов: `grep -cE` по регулярному выражению всей строки лога;
- топ-3 IP: `grep -oE` достает адрес по регулярному выражению, `awk` отбрасывает
  адреса с октетами больше 255, дальше `sort | uniq -c | sort` и `awk` для вывода;
- ответы 4xx и 5xx: `awk` сравнивает последнее поле строки с `^4[0-9][0-9]$` и `^5[0-9][0-9]$`;
- распределение по кодам и популярные эндпоинты: `awk`, `sed`, `sort`, `uniq`.

Анализ своего файла без генерации:

```bash
./analyze_logs.sh -a -f /var/log/nginx/access.log
```

## Docker Compose

```
клиент ──► proxy (nginx:alpine, порт 80) ──► api (hashicorp/http-echo, порт 8080)
          сети: frontend + backend            сеть: backend (internal)
```

- `api` отвечает текстом `Monitoring Service Active` на порту 8080. Он подключен
  только к внутренней сети `backend` (`internal: true`), поэтому с хоста к нему
  напрямую не обратиться.
- `proxy` подключен к обеим сетям, публикует порт 80 и передает запросы на `api:8080`.
  Адрес бэкенда подставляется в шаблон конфигурации из переменной `API_UPSTREAM`.
  Healthcheck прокси проверяет, что через него приходит ответ от `api`.

Запуск и проверка:

```bash
docker compose up -d
docker compose ps
curl http://localhost:80          # Monitoring Service Active
./check_api.sh http://localhost:80
```

Остановка:

```bash
docker compose down
```

Если стоит старый Compose v1, команды те же, только `docker-compose` через дефис.

## CI/CD

Пайплайн `.github/workflows/ci.yml` запускается на Pull Request в `main`,
на push в `main` и вручную.

| Job | Проверки |
|-----|----------|
| `lint` | `bash -n` для обоих скриптов, ShellCheck, `docker compose config` |
| `test-scripts` | `check_api.sh https://httpbin.org/status/200` с ожиданием кода 0 (до трех попыток, httpbin иногда отдает 5xx); код 1 на 404, закрытом порту, неверном URL и без аргументов; генерация лога и проверка, что в нем не меньше 300 строк |
| `test-compose` | `docker compose up -d --wait`, запрос через прокси с проверкой текста, проверка что порт 8080 не открыт на хосте |

`test-scripts` и `test-compose` запускаются только после успешного `lint`.

## Git workflow

- `main` защищена: прямой push запрещен, изменения попадают только через Pull Request с зеленым CI.
- `feature/monitoring` рабочая ветка, вся разработка ведется в ней.
- После завершения работы открывается Pull Request `feature/monitoring` → `main`.

## Деплой на сервер по SSH

В примерах сервер `203.0.113.20`, пользователь `deploy`, проект кладется в `/opt/infra-monitoring`.

### 1. Создаем SSH-ключ

```bash
ssh-keygen -t ed25519 -C "infra-monitoring deploy" -f ~/.ssh/infra_deploy
```

Получится два файла: закрытый ключ `~/.ssh/infra_deploy` (никому не передается)
и открытый `~/.ssh/infra_deploy.pub`, который копируется на сервер.
Ключ лучше защитить парольной фразой, `ssh-keygen` сам ее спросит.

### 2. Копируем открытый ключ на сервер

```bash
ssh-copy-id -i ~/.ssh/infra_deploy.pub deploy@203.0.113.20
```

`ssh-copy-id` один раз спросит пароль пользователя и допишет ключ в
`~/.ssh/authorized_keys` на сервере. Если `ssh-copy-id` нет (например, в Windows),
можно сделать то же самое вручную:

```bash
cat ~/.ssh/infra_deploy.pub | ssh deploy@203.0.113.20 \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Проверяем вход по ключу:

```bash
ssh -i ~/.ssh/infra_deploy deploy@203.0.113.20 'whoami && hostname'
```

Чтобы каждый раз не писать адрес и ключ, добавляем хост в `~/.ssh/config`:

```
Host monitoring
    HostName 203.0.113.20
    User deploy
    IdentityFile ~/.ssh/infra_deploy
```

После этого достаточно писать `ssh monitoring`. Когда вход по ключу работает,
на сервере стоит отключить вход по паролю: в `/etc/ssh/sshd_config` выставить
`PasswordAuthentication no` и `PermitRootLogin no`, затем `sudo systemctl restart ssh`.

### 3. Передаем проект через scp

```bash
# упаковываем проект без .git и логов
tar -czf infra-monitoring.tar.gz --exclude=.git --exclude='*.log' .

# копируем архив на сервер
scp infra-monitoring.tar.gz monitoring:/tmp/

# распаковываем
ssh monitoring 'sudo mkdir -p /opt/infra-monitoring && sudo chown deploy: /opt/infra-monitoring \
  && tar -xzf /tmp/infra-monitoring.tar.gz -C /opt/infra-monitoring && rm /tmp/infra-monitoring.tar.gz'
```

### 4. Или через tar + ssh одной командой

Архив передается потоком и не сохраняется на диск. Каталог `/opt/infra-monitoring`
должен уже существовать и принадлежать пользователю `deploy`, как в шаге 3:

```bash
tar -czf - --exclude=.git --exclude='*.log' . | ssh monitoring 'tar -xzf - -C /opt/infra-monitoring'
```

### 5. Запускаем стек на сервере

```bash
ssh monitoring 'cd /opt/infra-monitoring && docker compose pull && docker compose up -d'
ssh monitoring 'cd /opt/infra-monitoring && docker compose ps && ./check_api.sh http://localhost:80'
```

Для регулярной проверки доступности можно повесить скрипт на cron
(`crontab -e` на сервере), результат будет копиться в лог:

```
*/5 * * * * /opt/infra-monitoring/check_api.sh http://localhost:80 >> /home/deploy/api-check.log 2>&1
```
