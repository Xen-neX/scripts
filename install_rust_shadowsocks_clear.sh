#!/bin/bash

echo "Установка Shadowsocks Rust Transparent Proxy - Обновленная версия с REDIRECT для TCP и TPROXY для UDP"

# Проверяем, запущен ли уже shadowsocks.service и останавливаем его
if systemctl is-active --quiet shadowsocks.service; then
    echo "shadowsocks.service уже запущен. Останавливаю его..."
    systemctl stop shadowsocks.service
fi

# Сохраняем текущие настройки DNS
SYSTEM_DNS="$(cat /etc/resolv.conf)"

echo "Устанавливаю необходимые пакеты..."
apt-get update
apt-get install -y iptables iproute2 wget tar net-tools

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
tee /usr/local/bin/shadowsocks.sh > /dev/null <<EOF
#!/bin/bash

# Параметры сервера
SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
SERVER_PASSWORD="$SERVER_PASSWORD"
CUSTOM_RULES="$CUSTOM_RULES"
SYSTEM_DNS="\$SYSTEM_DNS"

# Лог файл sslocal
SSLOCAL_LOG="/var/log/sslocal.log"

start_sslocal() {
    echo "Запускаю sslocal..."

    # Останавливаем любые существующие процессы sslocal
    pkill -x sslocal

    # Запуск sslocal в режиме redir для прозрачного проксирования
    /usr/local/bin/sslocal -b "127.0.0.1:60080" \\
        --protocol redir \\
        -s "\$SERVER_IP:\$SERVER_PORT" \\
        -k "\$SERVER_PASSWORD" \\
        -m "chacha20-ietf-poly1305" \\
        --tcp-redir "redirect" \\
        --udp-redir "tproxy" \\
        &> "\$SSLOCAL_LOG" &

    SSLOCAL_PID=\$!
    sleep 2

    if ps -p \$SSLOCAL_PID > /dev/null; then
        echo "sslocal запущен с PID \$SSLOCAL_PID"
    else
        echo "Не удалось запустить sslocal. Проверьте \$SSLOCAL_LOG для деталей."
        exit 1
    fi
}

stop_sslocal() {
    echo "Останавливаю sslocal..."
    pkill -x sslocal
    sleep 1
    if pgrep -x sslocal > /dev/null; then
        echo "Не удалось остановить sslocal."
    else
        echo "sslocal остановлен."
    fi
}

start_iproute2() {
    echo "Настраиваю iproute2..."
    ip rule add fwmark 0x2333 lookup 100 2>/dev/null
    ip route add local default dev lo table 100 2>/dev/null
}

stop_iproute2() {
    echo "Очищаю iproute2..."
    ip rule del fwmark 0x2333 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null
}

start_iptables() {
    echo "Настраиваю iptables..."

    # Создаём и очищаем цепочки SSREDIR_TCP и SSREDIR_UDP в таблице mangle
    iptables -t mangle -N SSREDIR_TCP 2>/dev/null
    iptables -t mangle -F SSREDIR_TCP

    iptables -t mangle -N SSREDIR_UDP 2>/dev/null
    iptables -t mangle -F SSREDIR_UDP

    # Восстанавливаем метки соединений
    iptables -t mangle -A SSREDIR_TCP -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR_UDP -j CONNMARK --restore-mark

    # Исключаем сервер Shadowsocks из проксирования
    iptables -t mangle -A SSREDIR_TCP -p tcp -d \$SERVER_IP --dport \$SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR_UDP -p udp -d \$SERVER_IP --dport \$SERVER_PORT -j RETURN

    # Исключаем локальный трафик
    iptables -t mangle -A SSREDIR_TCP -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SSREDIR_UDP -d 127.0.0.0/8 -j RETURN

    if [ -n "\$CUSTOM_RULES" ]; then
        # Пользовательские правила
        PROTO_PORTS=(\$CUSTOM_RULES)
        COUNT=\${#PROTO_PORTS[@]}
        i=0
        while [ \$i -lt \$COUNT ]; do
            PROTO=\${PROTO_PORTS[\$i]}
            PORT=\${PROTO_PORTS[\$((i+1))]}
            i=\$((i+2))

            if [ "\$PROTO" = "tcp" ]; then
                iptables -t mangle -A SSREDIR_TCP -p tcp --dport \$PORT -j MARK --set-mark 0x2333
            elif [ "\$PROTO" = "udp" ]; then
                iptables -t mangle -A SSREDIR_UDP -p udp --dport \$PORT -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
            fi
        done
    else
        # Перенаправляем весь TCP и UDP трафик
        iptables -t mangle -A SSREDIR_TCP -p tcp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
        iptables -t mangle -A SSREDIR_UDP -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
    fi

    # Сохраняем метки соединений
    iptables -t mangle -A SSREDIR_TCP -j CONNMARK --save-mark
    iptables -t mangle -A SSREDIR_UDP -j CONNMARK --save-mark

    # Применяем цепочки SSREDIR_TCP и SSREDIR_UDP к PREROUTING и OUTPUT
    iptables -t mangle -A PREROUTING -p tcp -j SSREDIR_TCP
    iptables -t mangle -A PREROUTING -p udp -j SSREDIR_UDP
    iptables -t mangle -A OUTPUT -p tcp -j SSREDIR_TCP
    iptables -t mangle -A OUTPUT -p udp -j SSREDIR_UDP

    # Применяем REDIRECT для TCP-трафика
    iptables -t mangle -A SSREDIR_TCP -p tcp -m mark --mark 0x2333 -j REDIRECT --to-ports 60080

    # Применяем TPROXY для UDP-трафика
    iptables -t mangle -A SSREDIR_UDP -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 --tproxy-mark 0x2333/0x2333
}

stop_iptables() {
    echo "Очищаю iptables..."

    # Удаление правил REDIRECT для TCP
    iptables -t mangle -D SSREDIR_TCP -p tcp -m mark --mark 0x2333 -j REDIRECT --to-ports 60080 2>/dev/null

    # Удаление правил TPROXY для UDP
    iptables -t mangle -D SSREDIR_UDP -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 --tproxy-mark 0x2333/0x2333 2>/dev/null

    # Удаление цепочек SSREDIR_TCP и SSREDIR_UDP из PREROUTING и OUTPUT
    iptables -t mangle -D PREROUTING -p tcp -j SSREDIR_TCP 2>/dev/null
    iptables -t mangle -D PREROUTING -p udp -j SSREDIR_UDP 2>/dev/null
    iptables -t mangle -D OUTPUT -p tcp -j SSREDIR_TCP 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp -j SSREDIR_UDP 2>/dev/null

    # Очистка и удаление цепочек SSREDIR_TCP и SSREDIR_UDP
    iptables -t mangle -F SSREDIR_TCP 2>/dev/null
    iptables -t mangle -X SSREDIR_TCP 2>/dev/null
    iptables -t mangle -F SSREDIR_UDP 2>/dev/null
    iptables -t mangle -X SSREDIR_UDP 2>/dev/null

    # Очистка таблицы mangle
    iptables -t mangle -F 2>/dev/null
}

start_resolvconf() {
    echo "Настраиваю resolv.conf на публичный DNS (1.1.1.1)..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
}

stop_resolvconf() {
    echo "Восстанавливаю исходный resolv.conf..."
    echo "\$SYSTEM_DNS" > /etc/resolv.conf
}

start_iproute2() {
    echo "Настраиваю iproute2..."
    ip rule add fwmark 0x2333 lookup 100 2>/dev/null
    ip route add local default dev lo table 100 2>/dev/null
}

stop_iproute2() {
    echo "Очищаю iproute2..."
    ip rule del fwmark 0x2333 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null
}

start() {
    echo "Запуск процесса..."
    start_sslocal
    start_iproute2
    start_iptables
    start_resolvconf
    echo "Процесс запущен."
    # Чтобы скрипт не завершался, ожидаем завершения sslocal
    wait
}

stop() {
    echo "Остановка процесса..."
    stop_resolvconf
    stop_iptables
    stop_iproute2
    stop_sslocal
    echo "Процесс остановлен."
}

restart() {
    echo "Перезапуск процесса..."
    stop
    sleep 1
    start
}

main() {
    echo "Переданы аргументы: \$@"
    if [ \$# -eq 0 ]; then
        echo "Использование: \$0 {start|stop|restart}"
        exit 1
    fi

    case "\$1" in
        start)
            start
            ;;
        stop)
            stop
            ;;
        restart)
            restart
            ;;
        *)
            echo "Использование: \$0 {start|stop|restart}"
            exit 1
            ;;
    esac
}

main "\$@"
EOF

# Делаем скрипт исполняемым
chmod +x /usr/local/bin/shadowsocks.sh

# Создание systemd-сервиса
echo "Создаю systemd-сервис shadowsocks.service..."
tee /etc/systemd/system/shadowsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks Rust Transparent Proxy
After=network.target

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
systemctl daemon-reload
systemctl enable shadowsocks.service
systemctl start shadowsocks.service

# Проверка статуса сервиса
echo "Сервис shadowsocks.service запущен. Проверяю статус..."
systemctl status shadowsocks.service
