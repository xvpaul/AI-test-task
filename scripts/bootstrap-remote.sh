#!/usr/bin/env bash
#
# Выполняется НА СЕРВЕРЕ. Заливается через scp и запускается из deploy.yml.
# Идемпотентен: безопасно запускать на каждый деплой.
#
# Ожидает переменные окружения (все необязательные):
#   COMPOSE_DIR     куда клонировать репозиторий      (по умолчанию $HOME/openclaw)
#   OPENCLAW_DIR    каталог конфига                   (по умолчанию $HOME/.openclaw)
#   OPENCLAW_IMAGE  образ                             (по умолчанию ghcr.io/openclaw/openclaw:latest)
#   GATEWAY_TOKEN   токен дашборда                    (по умолчанию генерируется один раз)

set -euo pipefail

# Показать, на какой строке упали, — иначе ошибка теряется в выводе ssh
trap 'echo "ОШИБКА: строка ${LINENO}, код выхода $?" >&2' ERR

# git не должен ждать ввода логина/пароля: без TTY это выглядит как зависание
export GIT_TERMINAL_PROMPT=0

COMPOSE_DIR="${COMPOSE_DIR:-$HOME/openclaw}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"

# Тильда в кавычках не раскрывается — разворачиваем вручную,
# иначе получим каталог с буквальным именем "~"
COMPOSE_DIR="${COMPOSE_DIR/#\~/$HOME}"
OPENCLAW_DIR="${OPENCLAW_DIR/#\~/$HOME}"

echo "== Bootstrap OpenClaw =="
echo "compose : ${COMPOSE_DIR}"
echo "config  : ${OPENCLAW_DIR}"
echo "образ   : ${OPENCLAW_IMAGE}"

# --- Зависимости ------------------------------------------------------------
for cmd in docker git; do
  command -v "$cmd" >/dev/null || {
    echo "НЕТ: ${cmd} не установлен на сервере" >&2
    exit 1
  }
done
docker compose version >/dev/null 2>&1 || {
  echo "НЕТ: docker compose v2 недоступен" >&2
  exit 1
}
echo "зависимости на месте"

# --- Репозиторий ------------------------------------------------------------
if [ -d "${COMPOSE_DIR}/.git" ]; then
  echo "репозиторий уже есть, обновляю"
  git -C "${COMPOSE_DIR}" pull --ff-only || echo "  (pull не прошёл, работаю с текущей версией)"
elif [ -d "${COMPOSE_DIR}" ] && [ -n "$(ls -A "${COMPOSE_DIR}" 2>/dev/null || true)" ]; then
  # Остаток от прерванного клонирования либо чужой каталог.
  # Молча затирать чужие данные нельзя — останавливаемся.
  echo "НЕТ: ${COMPOSE_DIR} существует, не пуст и не является git-репозиторием." >&2
  echo "     Проверьте содержимое и удалите вручную, если это мусор от прошлой попытки." >&2
  exit 1
else
  echo "клонирую OpenClaw"
  git clone --depth 1 https://github.com/openclaw/openclaw.git "${COMPOSE_DIR}"
fi

[ -f "${COMPOSE_DIR}/docker-compose.yml" ] || [ -f "${COMPOSE_DIR}/docker-compose.yaml" ] || {
  echo "НЕТ: в ${COMPOSE_DIR} нет docker-compose.yml" >&2
  exit 1
}
echo "compose-файл найден"

mkdir -p "${OPENCLAW_DIR}"
cd "${COMPOSE_DIR}"

# --- Gateway-токен ----------------------------------------------------------
# Генерируем один раз: перезапись на каждом деплое ломала бы вход в дашборд.
if [ -f .env ] && grep -q '^OPENCLAW_GATEWAY_TOKEN=.\+' .env; then
  TOKEN="$(grep '^OPENCLAW_GATEWAY_TOKEN=' .env | cut -d= -f2-)"
  echo "токен уже задан, оставляю"
elif [ -n "${GATEWAY_TOKEN}" ]; then
  TOKEN="${GATEWAY_TOKEN}"
  echo "токен взят из секрета"
else
  TOKEN="$(openssl rand -hex 32)"
  echo "токен сгенерирован (посмотреть: grep TOKEN ${COMPOSE_DIR}/.env)"
fi

umask 077
cat > .env <<EOF
OPENCLAW_IMAGE=${OPENCLAW_IMAGE}
OPENCLAW_GATEWAY_TOKEN=${TOKEN}
OPENCLAW_SKIP_ONBOARDING=1
EOF
chmod 600 .env

echo "== Bootstrap завершён =="
