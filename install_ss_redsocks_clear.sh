#!/bin/bash

echo "Добро пожаловать в установщик Shadowsocks + Redsocks"
echo "Введите параметры для настройки:"

# Спрашиваем переменные у пользователя
read -p "IP удалённого сервера Shadowsocks: " SERVER_IP
read -p "Порт удалённого сервера Shadowsocks: " SERVER_PORT
read -p "Пароль для подключения к Shadowsocks: " SERVER_PASSWORD

# Проверка root-прав
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root."
  exit 1
fi

# Установка необходимых пакетов
echo "Установка Shadowsocks и Redsocks..."
apt update
apt install -y shadowsocks-libev redsocks

# Создание конфигурации Shadowsocks
echo "Создание конфигурации для Shadowsocks..."
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": "$SERVER_IP",
    "server_port": $SERVER_PORT,
    "local_port": 1080,
    "password": "$SERVER_PASSWORD",
    "method": "chacha20-ietf-poly1305",
    "fast_open": true,
    "mode": "tcp_and_udp"
}
EOF

# Создание конфигурации Redsocks
echo "Создание конфигурации для Redsocks..."
cat > /etc/redsocks.conf <<EOF
base {
    log = "file:/var/log/redsocks.log";
    daemon = on;
    user = redsocks;
    group = redsocks;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 1080;
    type = socks5;
}

redudp {
    local_ip = 127.0.0.1;
    local_port = 10053;
    ip = 127.0.0.1;
    port = 1080;
    dest_ip = 192.0.2.2;
    dest_port = 53;
    udp_timeout = 30;
    udp_timeout_stream = 180;
}

dnstc {
    local_ip = 127.0.0.1;
    local_port = 5300;
}
EOF

# Создание скрипта управления ss_redsocks.sh
echo "Создание скрипта управления ss_redsocks.sh..."
cat > /usr/local/bin/ss_redsocks.sh <<'EOL'
#!/bin/bash

SERVER_IP="$1"
SERVER_PORT="$2"

start() {
    echo "Запуск Shadowsocks и Redsocks..."
    systemctl start shadowsocks-libev
    systemctl start redsocks

    echo "Настройка iptables..."
    iptables -t nat -N REDSOCKS
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A OUTPUT -p tcp -d "$SERVER_IP" --dport "$SERVER_PORT" -j RETURN
    iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
    iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345
    iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
}

stop() {
    echo "Остановка Redsocks и Shadowsocks..."
    iptables -t nat -F REDSOCKS
    iptables -t nat -D OUTPUT -p tcp -j REDSOCKS
    iptables -t nat -X REDSOCKS
    systemctl stop redsocks
    systemctl stop shadowsocks-libev
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    *)
        echo "Использование: $0 {start|stop|restart}"
        exit 1
        ;;
esac
EOL
chmod +x /usr/local/bin/ss_redsocks.sh

# Создание systemd-сервиса
echo "Создание systemd-сервиса ss_redsocks.service..."
cat > /etc/systemd/system/ss_redsocks.service <<EOF
[Unit]
Description=Shadowsocks + Redsocks Service
After=network.target

[Service]
ExecStart=/usr/local/bin/ss_redsocks.sh start
ExecStop=/usr/local/bin/ss_redsocks.sh stop
ExecReload=/usr/local/bin/ss_redsocks.sh restart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка systemd и активация сервиса
systemctl daemon-reload
systemctl enable ss_redsocks
systemctl start ss_redsocks

echo "Установка завершена! Сервис ss_redsocks активирован."
