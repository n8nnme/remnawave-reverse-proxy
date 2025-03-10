#!/bin/bash

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

error() {
    echo -e "${COLOR_RED}[ERROR] $*${COLOR_RESET}"
    exit 1
}

check_os() {
    if ! grep -q "bullseye" /etc/os-release && ! grep -q "bookworm" /etc/os-release && ! grep -q "jammy" /etc/os-release && ! grep -q "noble" /etc/os-release; then
        error "Поддержка только Debian 11/12 и Ubuntu 22.04/24.04"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт нужно запускать с правами root"
    fi
}

generate_password() {
    local length=8
    tr -dc 'a-zA-Z' < /dev/urandom | fold -w $length | head -n 1
}

show_menu() {
    echo -e "${COLOR_GREEN}REMNAWAVE REVERSE-PROXY${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. Стандартная установка${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. Переустановить панель${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. Выбрать случайный шаблон для сайта${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. Выход${COLOR_RESET}"
}

extract_domain() {
    local SUBDOMAIN=$1
    echo "$SUBDOMAIN" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

check_certificates() {
    local DOMAIN=$1

    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
            echo "Сертификаты найдены в /etc/letsencrypt/live/$DOMAIN."
            return 0
        fi
    fi
    return 1
}

add_cron_rule() {
    local rule="$1"
    local logged_rule="${rule} >> /var/log/cron_jobs.log 2>&1"

    ( crontab -l | grep -Fxq "$logged_rule" ) || ( crontab -l 2>/dev/null; echo "$logged_rule" ) | crontab -
}

randomhtml() {
    cd /root/ || { echo "Ошибка: не удалось перейти в /root/"; exit 1; }

    echo -e "${COLOR_YELLOW}Установка случайного шаблона для $DOMAIN${COLOR_RESET}"
    sleep 2

    while ! wget -q --show-progress --timeout=30 --tries=10 --retry-connrefused "https://github.com/cortez24rus/xui-rp-web/archive/refs/heads/main.zip"; do
        echo "Скачивание не удалось, пробуем снова..."
        sleep 3
    done

    unzip main.zip &>/dev/null || { echo "Ошибка: не удалось распаковать архив"; exit 0; }
    rm -f main.zip

    cd simple-web-templates-main/ || { echo "Ошибка: не удалось перейти в распакованную директорию"; exit 0; }

    rm -rf assets ".gitattributes" "README.md" "_config.yml"

    RandomHTML=$(for i in *; do echo "$i"; done | shuf -n1 2>&1)
    echo "Выбран случайный шаблон: ${RandomHTML}"

    if [[ -d "${RandomHTML}" && -d "/var/www/html/" ]]; then
        rm -rf /var/www/html/*
        cp -a "${RandomHTML}"/. "/var/www/html/"
        echo "Шаблон успешно скопирован в /var/www/html/"
    else
        echo "Ошибка: не удалось скопировать шаблон" && exit 0
    fi

    cd /root/
    rm -rf simple-web-templates-main/
}

install_packages() {
    # Update
	echo -e "${COLOR_YELLOW}Установка необходимых пакетов...${COLOR_RESET}"
    apt-get update -y
    apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare

    if grep -q "Ubuntu" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    elif grep -q "Debian" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

	# Enable BBR
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi

	# Disable IPv6
    interface_name=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
    if ! grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv6.conf.default.disable_ipv6 = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv6.conf.lo.disable_ipv6 = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv6.conf.$interface_name.disable_ipv6 = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.$interface_name.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi

    sysctl -p > /dev/null 2>&1

	# UFW
    ufw --force reset
    ufw allow 22/tcp comment 'SSH'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable
    touch /usr/local/bin/install_packages
    clear
}

get_certificates() {
    local DOMAIN=$1
    local WILDCARD_DOMAIN="*.$DOMAIN"

	echo -e "${COLOR_YELLOW}Получаем сертификаты...${COLOR_RESET}"

    reading "Введите ваш Cloudflare API токен или глобальный API ключ:" CLOUDFLARE_API_KEY
    reading "Введите вашу почту, зарегистрированную на Cloudflare:" CLOUDFLARE_EMAIL

    check_api() {
        local attempts=3
        local attempt=1

        while [ $attempt -le $attempts ]; do
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
            else
                api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "Content-Type: application/json")
            fi

            if echo "$api_response" | grep -q '"success":true'; then
                echo -e "${COLOR_GREEN}Cloudflare API ключ и email валидны.${COLOR_RESET}"
                return 0
            else
                echo -e "${COLOR_RED}Ошибка: Неверный Cloudflare API ключ или email. Попытка $attempt из $attempts.${COLOR_RESET}"
                if [ $attempt -lt $attempts ]; then
                    read -p "Пожалуйста, введите ваш Cloudflare API ключ: " CLOUDFLARE_API_KEY
                    read -p "Пожалуйста, введите ваш Cloudflare email: " CLOUDFLARE_EMAIL
                fi
                attempt=$((attempt + 1))
            fi
        done
        error "Ошибка: Неверный Cloudflare API ключ или email после $attempts попыток."
    }

    check_api

    mkdir -p ~/.secrets/certbot
    if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
        cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
    else
        cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
    fi
    chmod 600 ~/.secrets/certbot/cloudflare.ini

    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        -d $DOMAIN \
        -d $WILDCARD_DOMAIN \
        --email $CLOUDFLARE_EMAIL \
        --agree-tos \
        --non-interactive \
        --key-type ecdsa \
        --elliptic-curve secp384r1

    echo "renew_hook = sh -c 'cd /root/remnawave && docker compose exec remnawave-nginx nginx -s reload'" >> /etc/letsencrypt/renewal/$DOMAIN.conf
    add_cron_rule "0 5 1 */2 * /usr/bin/certbot renew --quiet"
}

install_remnawave() {
    mkdir -p ~/remnawave && cd ~/remnawave

    reading "Введите ваш домен панели (например, panel.example.com):" PANEL_DOMAIN
    reading "Введите ваш домен подписки (например, sub.example.com):" SUB_DOMAIN

    DOMAIN=$(extract_domain $PANEL_DOMAIN)

    SUPERADMIN_USERNAME=$(generate_password)
    SUPERADMIN_PASSWORD=$(generate_password)

    METRICS_USER=$(generate_password)
    METRICS_PASS=$(generate_password)

    JWT_AUTH_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    JWT_API_TOKENS_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)

    cat > .env-node <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
SSL_CERT="PUBLIC KEY FROM REMNAWAVE-PANEL"
EOL

    cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
API_INSTANCES=1

### DATABASE ###
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### JWT ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET

### TELEGRAM ###
IS_TELEGRAM_ENABLED=false
TELEGRAM_BOT_TOKEN=
TELEGRAM_ADMIN_ID=
NODES_NOTIFY_CHAT_ID=

### FRONT_END ###
FRONT_END_DOMAIN=$PANEL_DOMAIN

### SUBSCRIPTION ###
SUB_SUPPORT_URL=
SUB_PROFILE_TITLE=SUBSCRIPTION
SUB_UPDATE_INTERVAL=12
SUB_WEBPAGE_URL=https://$PANEL_DOMAIN

### Remarks for expired, disabled and limited users
EXPIRED_USER_REMARKS=["⚠️ Subscription expired","Contact support"]
DISABLED_USER_REMARKS=["❌ Subscription disabled","Contact support"]
LIMITED_USER_REMARKS=["🔴 Subscription limited","Contact support"]

### SUBSCRIPTION PUBLIC DOMAIN ###
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### SUPERADMIN ###
SUPERADMIN_USERNAME=$SUPERADMIN_USERNAME
SUPERADMIN_PASSWORD=$SUPERADMIN_PASSWORD

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=true

### PROMETHEUS ###
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://webhook.site/1234567890
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### CLOUDFLARE ###
CLOUDFLARE_TOKEN=ey...

### Database ###
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    cat > docker-compose.yml <<EOL
services:
  remnawave-db:
    image: postgres:17
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file:
      - .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3000:3000'
    networks:
      - remnawave-network
    depends_on:
      remnawave-db:
        condition: service_healthy

  remnawave-nginx:
    image: nginx:1.27
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt/live/$DOMAIN/fullchain.pem:/etc/nginx/ssl/$DOMAIN/fullchain.pem:ro
      - /etc/letsencrypt/live/$DOMAIN/privkey.pem:/etc/nginx/ssl/$DOMAIN/privkey.pem:ro
      - /dev/shm:/dev/shm
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && nginx -g "daemon off;"'
    ports:
      - '80:80'
    networks:
      - remnawave-network
    depends_on:
      - remnawave
      - remnawave-json

  remnawave-json:
    image: ghcr.io/jolymmiles/remnawave-json:latest
    container_name: remnawave-json
    hostname: remnawave-json
    restart: always
    env_file:
      - ./remnawave-json/.env
    networks:
      - remnawave-network
    volumes:
    #   - path/to/templates/v2ray/default.json:/app/templates/v2ray/default.json
    #   - path/to/templates/mux/default.json:/app/templates/mux/default.json
      - ./remnawave-json/templates/subscription/index.html:/app/templates/subscription/index.html

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    env_file:
      - .env-node
    ports:
      - '443:443'
    volumes:
      - /dev/shm:/dev/shm
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
EOL

    cat > nginx.conf <<EOL
upstream remnawave {
    server remnawave:3000;
}

upstream json {
    server remnawave-json:4000;
}

map \$host \$backend {
    $PANEL_DOMAIN  http://remnawave;
    $SUB_DOMAIN    http://json;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220;

server {
    server_name $PANEL_DOMAIN $SUB_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$DOMAIN/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass \$backend;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;
}

server {
    listen 80 default_server;
    listen [::]:80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
EOL
	echo -e "${COLOR_YELLOW}Настройка remnawave-json...${COLOR_RESET}"
    git clone https://github.com/Jolymmiles/remnawave-json
    cd remnawave-json
    cat > .env <<EOL
REMNAWAVE_URL=https://$PANEL_DOMAIN
APP_PORT=4000
APP_HOST=0.0.0.0
# V2RAY_TEMPLATE_PATH=/app/templates/v2ray/default.json
# V2RAY_MUX_ENABLED=true
# V2RAY_MUX_TEMPLATE_PATH=/app/templates/v2ray/mux_default.json
WEB_PAGE_TEMPLATE_PATH=/app/templates/subscription/index.html
EOL
}

installation() {
    echo -e "${COLOR_YELLOW}Установка Remnawave${COLOR_RESET}"
    sleep 1

    install_remnawave
    DOMAIN=$(extract_domain $PANEL_DOMAIN)

    echo -e "${COLOR_YELLOW}Проверка наличия сертификатов...${COLOR_RESET}"
    sleep 1
    if check_certificates $DOMAIN; then
        echo -e "${COLOR_YELLOW}Используем существующие сертификаты.${COLOR_RESET}"
    else
		echo -e "${COLOR_RED}Cертификаты не найдены.${COLOR_RESET}"
        get_certificates $DOMAIN
    fi

    echo -e "${COLOR_YELLOW}Запуск Remnawave${COLOR_RESET}"
    sleep 1
    cd /root/remnawave
    docker compose up -d

    echo -e "${COLOR_YELLOW}Ожидаем завершения запуска...${COLOR_RESET}"
    sleep 15

    domain_url="127.0.0.1:3000"
    node_url="$DOMAIN"
    username="$SUPERADMIN_USERNAME"
    password="$SUPERADMIN_PASSWORD"
    target_dir="/root/remnawave"
    config_file="$target_dir/config.json"

    hashed_password=$(echo -n "$password" | md5sum | awk '{print $1}')

    echo -e "${COLOR_YELLOW}Выполняем запрос к API для получения токена...${COLOR_RESET}"
    sleep 1
    response=$(curl -s -X POST "http://$domain_url/api/auth/login" \
        -d "username=$username&password=$hashed_password" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https")

    if [ -z "$response" ]; then
        echo "Ошибка: Не удалось получить токен."
    fi

    token=$(echo "$response" | jq -r '.response.accessToken')
    if [ -z "$token" ]; then
        echo "Ошибка: Не удалось извлечь токен из ответа."
    fi

    echo "$token" > token.txt

    echo -e "${COLOR_YELLOW}Получаем публичный ключ...${COLOR_RESET}"
    sleep 1

    token=$(cat token.txt)
    api_response=$(curl -s -X GET "http://$domain_url/api/keygen/get" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https")

    if [ -z "$api_response" ]; then
        echo "Ошибка: Не удалось получить публичный ключ."
    fi

    pubkey=$(echo "$api_response" | jq -r '.response.pubKey')
    if [ -z "$pubkey" ]; then
        echo "Ошибка: Не удалось извлечь публичный ключ из ответа."
    fi

    echo -e "${COLOR_YELLOW}Публичный ключ успешно получен.${COLOR_RESET}"

    env_node_file="$target_dir/.env-node"
    cat > "$env_node_file" <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
SSL_CERT="$pubkey"
EOL

	# Генерация ключей x25519 с помощью Docker
	echo -e "${COLOR_YELLOW}Генерация ключей x25519...${COLOR_RESET}"
	sleep 1
    keys=$(docker run --rm ghcr.io/xtls/xray-core x25519)
    private_key=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
    public_key=$(echo "$keys" | grep "Public key:" | awk '{print $3}')

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        echo "Ошибка: Не удалось сгенерировать ключи."
    fi

    short_id=$(openssl rand -hex 8)
    cat > "$target_dir/config.json" <<EOL
{
    "log": {
        "loglevel": "debug"
    },
    "inbounds": [
        {
            "tag": "Steal",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "xver": 1,
                    "target": "/dev/shm/nginx.sock",
                    "spiderX": "",
                    "shortIds": [
                        "$short_id"
                    ],
                    "publicKey": "$public_key",
                    "privateKey": "$private_key",
                    "serverNames": [
                        "$DOMAIN"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "tag": "DIRECT",
            "protocol": "freedom"
        },
        {
            "tag": "BLOCK",
            "protocol": "blackhole"
        }
    ],
    "routing": {
        "rules": [
            {
                "ip": [
                    "geoip:private"
                ],
                "type": "field",
                "outboundTag": "BLOCK"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:private"
                ],
                "outboundTag": "BLOCK"
            },
            {
                "type": "field",
                "protocol": [
                    "bittorrent"
                ],
                "outboundTag": "BLOCK"
            }
        ]
    }
}
EOL

	echo -e "${COLOR_YELLOW}Обновление конфигурации Xray...${COLOR_RESET}"
	sleep 1
    NEW_CONFIG=$(cat "$config_file")
    update_response=$(curl -s -X POST "http://$domain_url/api/xray/update-config" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https" \
        -d "$NEW_CONFIG")

    if [ -z "$update_response" ]; then
        echo "Ошибка: Пустой ответ от сервера при обновлении конфигурации."
    fi

    if echo "$update_response" | jq -e '.response.config' > /dev/null; then
        echo -e "${COLOR_YELLOW}Конфигурация Xray успешно обновлена.${COLOR_RESET}"
        sleep 1
    else
        echo "Ошибка: Не удалось обновить конфигурацию Xray."
    fi

    NEW_NODE_DATA=$(cat <<EOF
{
    "name": "Steal",
    "address": "remnanode",
    "port": 2222,
    "isTrafficTrackingActive": false,
    "trafficLimitBytes": 0,
    "notifyPercent": 0,
    "trafficResetDay": 31,
    "excludedInbounds": [],
    "countryCode": "XX",
    "consumptionMultiplier": 1.0
}
EOF
)
    node_response=$(curl -s -X POST "http://$domain_url/api/nodes/create" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https" \
        -d "$NEW_NODE_DATA")

    if [ -z "$node_response" ]; then
        echo "Ошибка: Пустой ответ от сервера при создании узла."
    fi

    if echo "$node_response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_YELLOW}Узел успешно создан.${COLOR_RESET}"
    else
        echo "Ошибка: Не удалось создать узел."
    fi

    inbounds_response=$(curl -s -X GET "http://$domain_url/api/inbounds" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https")

    if [ -z "$inbounds_response" ]; then
        echo "Ошибка: Пустой ответ от сервера при получении inbounds."
    fi

    inbound_uuid=$(echo "$inbounds_response" | jq -r '.response[0].uuid')
    if [ -z "$inbound_uuid" ]; then
        echo "Ошибка: Не удалось извлечь UUID из ответа."
    fi
	echo -e "${COLOR_YELLOW}Создаем хост с UUID: $inbound_uuid...${COLOR_RESET}"
    host_data=$(cat <<EOF
{
    "inboundUuid": "$inbound_uuid",
    "remark": "Steal",
    "address": "$DOMAIN",
    "port": 443,
    "path": "",
    "sni": "$DOMAIN",
    "host": "$DOMAIN",
    "alpn": "h2",
    "fingerprint": "chrome",
    "allowInsecure": false,
    "isDisabled": false
}
EOF
)

    host_response=$(curl -s -X POST "http://$domain_url/api/hosts/create" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -H "Host: $PANEL_DOMAIN" \
        -H "X-Forwarded-For: $domain_url" \
        -H "X-Forwarded-Proto: https" \
        -d "$host_data")

    if [ -z "$host_response" ]; then
        echo "Ошибка: Пустой ответ от сервера при создании хоста."
    fi

    if echo "$host_response" | jq -e '.response.uuid' > /dev/null; then
	echo -e "${COLOR_YELLOW}Хост успешно создан.${COLOR_RESET}"
    else
        echo "Ошибка: Не удалось создать хост."
    fi

    sleep 2
    echo -e "${COLOR_YELLOW}Остановка Remnawave${COLOR_RESET}"
    docker compose down
    sleep 10
    echo -e "${COLOR_YELLOW}Запуск Remnawave${COLOR_RESET}"
    docker compose up -d
    sleep 10
    wget -O /root/install_remnawave.sh https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh
    ln -s /root/install_remnawave.sh /usr/local/bin/remnawave_reverse
    chmod +x install_remnawave.sh

    clear

    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}               УСТАНОВКА ЗАВЕРШЕНА!${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Панель доступна по адресу:${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://$PANEL_DOMAIN${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Для входа в панель используйте следующие данные:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Логин: ${COLOR_WHITE}$SUPERADMIN_USERNAME${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Пароль: ${COLOR_WHITE}$SUPERADMIN_PASSWORD${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Чтобы заново вызвать скрипт, используйте команду:${COLOR_RESET}"
    echo -e "${COLOR_WHITE}remnawave_reverse${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"

    randomhtml
}

check_os
check_root
show_menu
reading "Выберите действие (1-4):" OPTION

case $OPTION in
    1)
        if [ ! -f /usr/local/bin/install_packages ]; then
	    install_packages
	fi
	installation
        ;;
    2)
        cd /root/remnawave
        docker compose down -v --rmi all --remove-orphans
        rm -rf /root/remnawave
        installation
        ;;
    3)
        randomhtml
        ;;
    4)
        echo -e "${COLOR_YELLOW}Выход.${COLOR_RESET}"
        exit 0
        ;;
    *)
        echo -e "${COLOR_YELLOW}Неверный выбор. Пожалуйста, выберите опцию от 1 до 4.${COLOR_RESET}"
        exit 1
        ;;
esac
exit 0
