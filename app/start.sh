#!/bin/bash
# Стартовый скрипт контейнера: поднимает GPS-сервер как фоновый демон
# (с авто-перезапуском при падении) и Apache в foreground.

set -e

GPS_DIR=${GPS_DIR:-/opt/gps-server}
GPS_LOG=/var/log/gps-server.log

# Генерируем settings из переменных окружения (с дефолтами)
cat > "$GPS_DIR/settings" <<EOF
[main]

port      = ${GPS_PORT:-5000}
timezone  = ${GPS_TIMEZONE:-5}
delay     = ${GPS_DELAY:-30}


[database]

ip       = ${DB_HOST:-db}
schema   = ${DB_NAME:-test}
user     = ${DB_USER:-test}
password = ${DB_PASSWORD:?DB_PASSWORD не задан}
EOF

# Пароли задаются при старте из env, а не при сборке: в образе нет секретов
if [ -n "$SYS_PASS" ]; then
  echo "${SYS_USER:-app}:$SYS_PASS" | chpasswd
fi
htpasswd -bc /etc/apache2/.htpasswd "${APACHE_USER:?APACHE_USER не задан}" "${APACHE_PASS:?APACHE_PASS не задан}"


# GPS-сервер как фоновый демон с авто-перезапуском
(
  cd "$GPS_DIR"
  while true; do
    echo "[$(date '+%F %T')] запуск gps-server-h01" >> "$GPS_LOG"
    stdbuf -oL -eL ./gps-server-h01 >> "$GPS_LOG" 2>&1
    echo "[$(date '+%F %T')] gps-server-h01 завершился (код $?), перезапуск через 3с" >> "$GPS_LOG"
    sleep 3
  done
) &


# Apache в foreground — основной процесс контейнера (PID 1)
exec apachectl -D FOREGROUND

