#!/bin/bash

echo "Установка Shadowsocks Rust Transparent Proxy - Полная версия"

# Проверяем, запущена ли уже shadowsocks.service и останавливаем её
if systemctl is-active --quiet shadowsocks.service; then
    echo "shadowsocks.service уже запущен. Останавливаю его..."
    systemctl stop shadowsocks.service
fi

# Сохраняем текущие настройки DNS
SYSTEM_DNS="$(cat /etc/resolv.conf)"

echo "Устанавливаю необходимые пакеты..."
apt-get update
apt-get install -y iptables iproute2 wget tar

# Скачиваем shadowsocks-rust
VERSION="v1.21.2"
DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/shadowsocks-${VERSION}.x86_64-unknown-linux-gnu.tar.xz"

echo "Скачиваю Shadowsocks-rust версии ${VERSION}..."
wget "${DOWNLOAD_URL}" -O /tmp/shadowsocks.tar.xz

echo "Распаковываю архив..."
tar -xvf /tmp/shadowsocks.tar.xz -C /tmp/

# Проверяем, существует ли sslocal в /tmp/
SSLOCAL_SRC="/tmp/sslocal"
if [ ! -f "$SSLOCAL_SRC" ]; then
    echo "Ошибка: sslocal не найден в /tmp/ после распаковки архива."
    echo "Содержимое /tmp/ после распаковки:"
    ls -l /tmp | grep sslocal
    exit 1
fi

echo "Перемещаю sslocal в /usr/local/bin/..."
mv "$SSLOCAL_SRC" /usr/local/bin/
chown root:root /usr/local/bin/sslocal
chmod +x /usr/local/bin/sslocal

# Очистка временных файлов
rm -rf /tmp/shadowsocks.tar.xz /tmp/shadowsocks-*

# Создание директории для логов, если не существует
mkdir -p /var/log
touch /var/log/sslocal.log
chown root:root /var/log/sslocal.log
chmod 644 /var/log/sslocal.log

# Запрос параметров у пользователя
read -p "Введите IP-адрес сервера Shadowsocks: " SERVER_IP
read -p "Введите порт сервера Shadowsocks: " SERVER_PORT
read -p "Введите пароль для Shadowsocks: " SERVER_PASSWORD

# Запрос пользовательских правил перенаправления
echo "Укажите протоколы и порты для перенаправления через Shadowsocks."
echo "Формат: tcp 443 tcp 80 udp 53"
echo "Если оставить пустым (нажать Enter), будет перенаправлен весь TCP и UDP трафик."
read -p "Протоколы и порты: " CUSTOM_RULES

# Создание скрипта управления Shadowsocks
echo "Создаю скрипт управления Shadowsocks..."
sudo tee /usr/local/bin/shadowsocks.sh > /dev/null <<EOF
#!/bin/bash

# Параметры сервера
SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
SERVER_PASSWORD="$SERVER_PASSWORD"
CUSTOM_RULES="$CUSTOM_RULES"
SYSTEM_DNS="\$SYSTEM_DNS"
SSLOCAL_PORT=60080 # Определяем порт sslocal

# Лог файл sslocal
SSLOCAL_LOG="/var/log/sslocal.log"

start_sslocal() {
    echo "Запускаю sslocal..."
    pkill -x sslocal # Останавливаем предыдущие экземпляры

    /usr/local/bin/sslocal -b "127.0.0.1:\$SSLOCAL_PORT" \
        --protocol redir \
        -s "\$SERVER_IP:\$SERVER_PORT" \
        -k "\$SERVER_PASSWORD" \
        -m "chacha20-ietf-poly1305" \
        --tcp-redir "redirect" \
        --udp-redir "tproxy" \
        &> "\$SSLOCAL_LOG" &

    sleep 2
    if ! pgrep -x sslocal > /dev/null; then # Проверка с отрицанием
        echo "Не удалось запустить sslocal. Проверьте \$SSLOCAL_LOG для деталей."
        exit 1
    fi
    echo "sslocal запущен."
}

stop_sslocal() {
    echo "Останавливаю sslocal..."
    pkill -x sslocal
}

start_iproute2() {
    echo "Настраиваю iproute2..."
    ip rule add fwmark 0x1/0x1 lookup 100 2>/dev/null # Исправлено правило ip
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null # Исправлено правило ip
}

stop_iproute2() {
    echo "Очищаю iproute2..."
    ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null # Исправлено правило ip
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null # Исправлено правило ip
}

start_iptables() {
    echo "Настраиваю iptables..."
    sudo iptables -t mangle -F
    sudo iptables -t mangle -X SSREDIR 2>/dev/null
    sudo iptables -t mangle -N SSREDIR

    # Исключения
    sudo iptables -t mangle -A SSREDIR -d 127.0.0.0/8 -j RETURN
    sudo iptables -t mangle -A SSREDIR -d "\$SERVER_IP" -j RETURN

    if [ -n "\$CUSTOM_RULES" ]; then
        PROTO_PORTS=(\$CUSTOM_RULES)
        COUNT=\${#PROTO_PORTS[@]}
        i=0
        while [ \$i -lt \$COUNT ]; do
            PROTO=\${PROTO_PORTS[\$i]}
            PORT=\${PROTO_PORTS[\$((i+1))]}
            i=\$((i+2))
            if [ "\$PROTO" = "tcp" ]; then
                sudo iptables -t mangle -A SSREDIR -p tcp --dport \$PORT -j MARK --set-mark 0x1
            elif [ "\$PROTO" = "udp" ]; then
                sudo iptables -t mangle -A SSREDIR -p udp --dport \$PORT -j MARK --set-mark 0x1
            fi
        done
    else
        sudo iptables -t mangle -A SSREDIR -p tcp -j MARK --set-mark 0x1
        sudo iptables -t mangle -A SSREDIR -p udp -j MARK --set-mark 0x1
    fi

    sudo iptables -t nat -F
    sudo iptables -t nat -A PREROUTING -m mark --mark 0x1 -j TPROXY --on-ip 127.0.0.1 --on-port \$SSLOCAL_PORT
}

stop_iptables() {
    echo "Очищаю iptables..."
    sudo iptables -t nat -F
    sudo iptables -t mangle -F SSREDIR
    sudo iptables -t mangle -X SSREDIR
}

start_resolvconf() {
    echo "Настраиваю resolv.conf на публичный DNS (1.1.1.1)..."
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null # Использование tee с sudo
}

stop_resolvconf() {
    echo "Восстанавливаю исходный resolv.conf..."
    echo "\$SYSTEM_DNS" | sudo tee /etc/resolv.conf > /dev/null # Использование tee с sudo
}

start() {
    start_sslocal
    start_iproute2
    start_iptables
    start_resolvconf
    echo "Процесс запущен."
}

stop() {
    stop_resolvconf
    stop_iptables
    stop_iproute2
    stop_sslocal
    echo "Процесс остановлен."
}

restart() {
    stop
    sleep 1
    start
}

main() {
    if [ \$# -eq 0 ]; then
        echo "Использование: \$0 {start|stop|restart}"
        exit 1
    fi

    case "\$1" in
        start|stop|restart)
            "$1"
            ;;
        *)
            echo "Неизвестная команда: \$1"
            echo "Использование: \$0 {start|stop|restart}"
            exit 1
            ;;
    esac
}

main "$@"
EOF

sudo chmod +x /usr/local/bin/shadowsocks.sh

# Создание systemd-сервиса
echo "Создаю systemd-сервис shadowsocks.service..."
sudo tee /etc/systemd/system/shadowsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks Rust Transparent Proxy
After=network-online.target

[Service]
ExecStart=/usr/local/bin/shadowsocks.sh start
ExecStop=/usr/local/bin/shadowsocks.sh stop
Restart=on-failure
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# Активация и запуск сервиса
echo "Активирую и запускаю сервис shadowsocks.service..."
sudo systemctl daemon-reload
sudo systemctl enable shadowsocks.service
sudo systemctl start shadowsocks.service

# Проверка статуса сервиса
echo "Сервис shadowsocks.service запущен. Проверяю статус..."
sudo systemctl status shadowsocks.service
