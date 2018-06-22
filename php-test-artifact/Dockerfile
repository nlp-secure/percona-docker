FROM php:7.2

ENV DEBIAN_FRONTEND=noninteractive
ENV TIMEZONE=America/Denver
env YARN_CACHE_FOLDER=/tmp/yarn-cache
env XDG_CACHE_HOME=/tmp/xdg-cache-home

RUN echo "$TIMEZONE" > /etc/timezone && \
    cp /usr/share/zoneinfo/$TIMEZONE /etc/localtime && \
    dpkg-reconfigure tzdata

WORKDIR /app
COPY app /app

RUN set -e && set -x && \
    apt-get update -y && \
    apt-get upgrade -y && \
    apt-get install -y openssl zip unzip git gnupg libpng-dev && \
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
    docker-php-ext-install -j$(nproc) pdo mbstring && \
    curl -sL https://deb.nodesource.com/setup_10.x | bash - && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get update && \
    apt-get install -y nodejs yarn && \
    curl -Lo /usr/bin/gosu https://github.com/tianon/gosu/releases/download/1.10/gosu-amd64 && chmod +x /usr/bin/gosu && \
    cat /etc/passwd && \
    chown -R nobody . && \
    gosu nobody composer install && \
    gosu nobody yarn --no-install-recommends && \
    gosu nobody yarn run production && \
    chown -R root . && \
    apt-get remove -y cpp gcc g++ git gnupg autoconf cpp make nodejs rsync && \
    apt autoremove -y && \
    rm -rf /tmp/.[a-zA-Z0-9]* /tmp/[a-zA-Z0-9]* && \
    apt-get clean

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /app/storage
VOLUME /app/bootstrap/cache

ENTRYPOINT /entrypoint.sh

EXPOSE 80