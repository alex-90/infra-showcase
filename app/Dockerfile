# Базовый образ (24.04 — штатный PHP 8.3, нужен для composer.lock проекта)
FROM ubuntu:24.04

ENV TZ=Asia/Yekaterinburg
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Зеркало Yandex вместо archive.ubuntu.com (в 24.04 источники в ubuntu.sources)
RUN sed -i 's|archive.ubuntu.com|mirror.yandex.ru|g' /etc/apt/sources.list.d/ubuntu.sources

# Пакеты: Apache+PHP, клиент MariaDB, сборка GPS-сервера, утилиты.
# Кэш-монтирование BuildKit: скачанные .deb и списки пакетов хранятся в
# постоянном кэше сборки (вне образа), поэтому при пересборке качаются
# только новые/изменённые пакеты. docker-clean убираем, чтобы apt не
# затирал кэш архивов после установки.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        php php-mysql php-cli php-pdo \
        php-mbstring php-xml php-gd php-zip php-bcmath \
        libapache2-mod-php \
        mariadb-client \
        libmysqlclient-dev \
        ca-certificates \
        gcc make vim curl telnet iputils-ping

# Composer (бинарник из официального образа — без лишних зависимостей)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Системный пользователь (логин/пароль из env)
ARG SYS_USER=app
RUN useradd -m -s /bin/bash "$SYS_USER" && \
    usermod -aG sudo "$SYS_USER"

# Каталог GPS-сервера в домашней папке пользователя (ENV доступен и в start.sh)
ENV GPS_DIR=/home/$SYS_USER/gps-server-h01

# GPS-сервер и конфиги
COPY ./gps-server-h01 $GPS_DIR
COPY ./apache-auth.conf /etc/apache2/sites-available/000-default.conf
COPY ./php.ini /etc/php/8.3/apache2/php.ini

# Права
RUN chown -R www-data:www-data /var/www/html && \
    chown -R "$SYS_USER":"$SYS_USER" "$GPS_DIR"

# Компилируем GPS-сервер при сборке
RUN cd "$GPS_DIR" && make

# Apache: модули и алиас
RUN a2enmod rewrite headers && \
    echo "alias ll='ls -l'" >> /home/$SYS_USER/.bashrc



# Стартовый скрипт: GPS-сервер (демон) + Apache (foreground)
COPY ./start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Порт GPS-сервера
EXPOSE 5000

CMD ["/usr/local/bin/start.sh"]

