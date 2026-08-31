#!/usr/bin/env bash
#
# Выполняется НА СЕРВЕРЕ после доставки конфига. Заливается через scp из deploy.yml.
#
# Задача: привести владельца каталога конфига к пользователю внутри контейнера
# и перезапустить сервис.
#
# Зачем chown: CI подключается под root, поэтому mkdir и scp создают файлы
# с владельцем root:root. Внутри образа процесс работает под пользователем node
# (обычно uid 1000) и не может писать в свой state-каталог — контейнер падает
# с EACCES на openclaw.sqlite-wal и уходит в цикл перезапусков.
#
# Переменные окружения (необязательные):
#   COMPOSE_DIR, OPENCLAW_DIR, OPENCLAW_IMAGE

set -euo pipefail
trap 'echo "ОШИБКА: строка ${LINENO}, код выхода $?" >&2' ERR

COMPOSE_DIR="${COMPOSE_DIR:-$HOME/openclaw}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
COMPOSE_DIR="${COMPOSE_DIR/#\~/$HOME}"
OPENCLAW_DIR="${OPENCLAW_DIR/#\~/$HOME}"

SERVICE="openclaw-gateway"
cd "${COMPOSE_DIR}"

# --- Владелец каталога конфига ---------------------------------------------
# UID/GID спрашиваем у самого образа, а не хардкодим 1000: если сборка
# сменит пользователя, хардкод сломается молча.
echo "== Права на ${OPENCLAW_DIR} =="
if IDS="$(docker run --rm --entrypoint sh "${OPENCLAW_IMAGE}" -c 'id -u; id -g' 2>/dev/null | paste -sd: -)" \
   && [ "${IDS}" != ":" ] && [ -n "${IDS}" ]; then
  echo "пользователь внутри образа: ${IDS}"
else
  IDS="1000:1000"
  echo "не удалось спросить образ, беру значение по умолчанию: ${IDS}"
fi

# chown -R выполняем ВСЕГДА, без проверки «а вдруг уже правильно».
# Проверка по владельцу самого каталога была ошибкой: scp поверх
# существующего файла сохраняет inode и владельца, а новые файлы создаёт
# от root. Каталог при этом остаётся корректным, проверка проходит,
# и свежий root-овский файл остаётся незамеченным — ровно так конфиг
# и оказался недоступен процессу внутри контейнера.
echo "выставляю владельца ${IDS} на весь каталог"
chown -R "${IDS}" "${OPENCLAW_DIR}"

# Показать результат: если что-то опять не так, это будет видно в логе деплоя
echo "содержимое ${OPENCLAW_DIR}:"
ls -la "${OPENCLAW_DIR}" | sed 's/^/  /'

if find "${OPENCLAW_DIR}" -maxdepth 1 ! -user "${IDS%%:*}" -print -quit | grep -q .; then
  echo "НЕТ: остались файлы с чужим владельцем" >&2
  exit 1
fi

# --- Конфиг на месте? -------------------------------------------------------
# Шлюз читает строго ~/.openclaw/openclaw.json. Файл с любым другим именем
# молча игнорируется, шлюз стартует на дефолтах и падает с "Missing config".
CONFIG="${OPENCLAW_DIR}/openclaw.json"
if [ ! -f "${CONFIG}" ]; then
  echo "НЕТ: не найден ${CONFIG}" >&2
  echo "     Шлюз читает только это имя — проверьте шаг доставки конфига." >&2
  echo "     Содержимое каталога:" >&2
  ls -la "${OPENCLAW_DIR}" >&2
  exit 1
fi
echo "конфиг на месте: ${CONFIG} ($(wc -l < "${CONFIG}") строк)"

# Остаток от прежних деплоев под неправильным именем — только путает
rm -f "${OPENCLAW_DIR}/openclaw.config.json5"

# --- Перезапуск -------------------------------------------------------------
# up -d, а не restart: restart не перечитывает переменные окружения
echo "== Перезапуск ${SERVICE} =="
docker compose up -d "${SERVICE}"

# --- Ожидание готовности ----------------------------------------------------
# Ждём по факту, а не фиксированным sleep: healthcheck может занять
# от пары секунд до полуминуты в зависимости от нагрузки VPS.
echo "== Ожидание готовности (до 90 с) =="
deadline=$(( $(date +%s) + 90 ))
status=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  cid="$(docker compose ps -q "${SERVICE}")"
  [ -n "${cid}" ] || { sleep 3; continue; }

  # У образа может не быть healthcheck — тогда ориентируемся на running
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo unknown)"
  running="$(docker inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null || echo false)"
  restarts="$(docker inspect -f '{{.RestartCount}}' "${cid}" 2>/dev/null || echo 0)"

  if [ "${health}" = "healthy" ] || { [ "${health}" = "none" ] && [ "${running}" = "true" ]; }; then
    status="ok"; break
  fi
  if [ "${restarts}" -gt 3 ]; then
    status="crashloop"; break
  fi
  sleep 3
done

echo
docker compose ps "${SERVICE}"
echo
echo "== Последние логи =="
docker compose logs --tail=40 "${SERVICE}"

case "${status}" in
  ok)
    echo
    echo "== Сервис поднялся =="
    ;;
  crashloop)
    echo
    echo "НЕТ: контейнер перезапускается циклически — смотрите логи выше" >&2
    exit 1
    ;;
  *)
    echo
    echo "НЕТ: сервис не пришёл в рабочее состояние за 90 секунд" >&2
    exit 1
    ;;
esac
