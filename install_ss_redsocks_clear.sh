#!/bin/bash
# Установка необходимых пакетов
echo "Устанавливаю необходимые пакеты..."
apt-get update
apt-get install -y shadowsocks-libev redsocks

# Запрос параметров от пользователя
read -p "Введите IP-адрес Shadowsocks-сервера: " SERVER_IP
read -p "Введите порт Shadowsocks-сервера: " SERVER_PORT
read -p "Введите пароль Shadowsocks: " SERVER_PASSWORD

# Создание конфигурационного файла Shadowsocks
echo "Создаю конфигурацию Shadowsocks..."
tee /etc/shadowsocks-libev/config.json > /dev/null <<EOF
{
    "server": "$SERVER_IP",
    "server_port": $SERVER_PORT,
    "local_port": 1080,
    "password": "$SERVER_PASSWORD",
    "method": "chacha20-ietf-poly1305",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

# Создание конфигурационного файла Redsocks
echo "Создаю конфигурацию Redsocks..."
tee /etc/redsocks.conf > /dev/null <<EOF
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

# Создание скрипта для запуска Shadowsocks и Redsocks
echo "Создаю скрипт для запуска Shadowsocks и Redsocks..."
tee /usr/local/bin/ss_redsocks.sh > /dev/null <<EOF
#!/bin/bash

SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"

start_shadowsocks() {
    echo "Запускаю Shadowsocks..."
    nohup ss-local -c /etc/shadowsocks-libev/config.json &>/var/log/shadowsocks.log &
}

stop_shadowsocks() {
    echo "Останавливаю Shadowsocks..."
    pkill -f ss-local
}

start_redsocks() {
    echo "Запускаю Redsocks..."
    nohup redsocks -c /etc/redsocks.conf &>/var/log/redsocks.log &
}

stop_redsocks() {
    echo "Останавливаю Redsocks..."
    pkill -f redsocks
}

configure_iptables() {
    echo "Настраиваю iptables..."
    YOUR_SERVER_IP=\$(hostname -I | awk '{print \$1}')

    /usr/sbin/iptables -t nat -F
    /usr/sbin/iptables -t nat -N REDSOCKS

    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d \$YOUR_SERVER_IP -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN

    /usr/sbin/iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
    /usr/sbin/iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345

    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
}

start() {
    start_shadowsocks
    start_redsocks
    configure_iptables
    echo "Все сервисы запущены."
}

stop() {
    stop_shadowsocks
    stop_redsocks

    echo "Очищаю iptables..."
    /usr/sbin/iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -F REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -X REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -F 2>/dev/null

    echo "Все сервисы остановлены и iptables восстановлен."
}

restart() {
    stop
    sleep 1
    start
}

main() {
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

chmod +x /usr/local/bin/ss_redsocks.sh

# Создание systemd-сервиса
echo "Создаю systemd-сервис..."
tee /etc/systemd/system/ss_redsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks + Redsocks Service
After=network.target

[Service]
ExecStart=/usr/local/bin/ss_redsocks.sh start
ExecStop=/usr/local/bin/ss_redsocks.sh stop
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка systemd, активация и запуск сервиса
echo "Активирую и запускаю сервис ss_redsocks..."
systemctl daemon-reload
systemctl enable ss_redsocks.service
systemctl start ss_redsocks.service

echo "Проверка статуса:"
systemctl status ss_redsocks.service
