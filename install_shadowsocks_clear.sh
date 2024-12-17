#!/bin/bash

# Перед запуском: если сервис уже запущен, останавливаем его
if systemctl is-active --quiet ss_redsocks.service; then
    echo "Обнаружен запущенный сервис ss_redsocks.service. Останавливаю..."
    systemctl stop ss_redsocks.service
fi

echo "Устанавливаю необходимые пакеты..."
apt-get update
apt-get install -y shadowsocks-libev redsocks

# Запрос параметров от пользователя
read -p "Введите IP-адрес Shadowsocks-сервера: " SERVER_IP
read -p "Введите порт Shadowsocks-сервера: " SERVER_PORT
read -p "Введите пароль Shadowsocks: " SERVER_PASSWORD

YOUR_SERVER_IP=$(hostname -I | awk '{print $1}')
BACKUP_FILE="/root/iptables_backup_ss_redsocks.save"

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

echo "Создаю основной скрипт /usr/local/bin/ss_redsocks.sh..."
tee /usr/local/bin/ss_redsocks.sh > /dev/null <<EOF
#!/bin/bash

SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
YOUR_SERVER_IP="$YOUR_SERVER_IP"
BACKUP_FILE="$BACKUP_FILE"

start_shadowsocks() {
    echo "Запускаю Shadowsocks..."
    nohup ss-local -c /etc/shadowsocks-libev/config.json &>/var/log/shadowsocks.log &
}

stop_shadowsocks() {
    echo "Останавливаю Shadowsocks..."
    pkill -x ss-local
}

start_redsocks() {
    echo "Запускаю Redsocks..."
    nohup redsocks -c /etc/redsocks.conf &>/var/log/redsocks.log &
}

stop_redsocks() {
    echo "Останавливаю Redsocks..."
    pkill -x redsocks
}

configure_iptables() {
    echo "Делаю бэкап iptables в \$BACKUP_FILE"
    /usr/sbin/iptables-save > "\$BACKUP_FILE" || { echo "Не удалось сделать бэкап iptables!"; exit 1; }

    echo "Настраиваю iptables..."
    /usr/sbin/iptables -t nat -N REDSOCKS 2>/dev/null

    /usr/sbin/iptables -t nat -A OUTPUT -d 127.0.0.0/8 -p tcp -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -d \$YOUR_SERVER_IP -p tcp -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -d \$SERVER_IP -p tcp --dport \$SERVER_PORT -j RETURN

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
    echo "Процессы остановлены. Восстановление iptables будет выполнено ExecStopPost."
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

echo "Создаю скрипт восстановления iptables /usr/local/bin/restore_iptables.sh..."
tee /usr/local/bin/restore_iptables.sh > /dev/null <<EOF
#!/bin/bash
if [ -f "$BACKUP_FILE" ]; then
    echo "Восстанавливаю iptables из \$BACKUP_FILE"
    cat "$BACKUP_FILE" | /usr/sbin/iptables-restore || echo "Ошибка при восстановлении iptables!"
    rm "$BACKUP_FILE"
else
    echo "Файл бэкапа iptables не найден!"
fi
EOF

chmod +x /usr/local/bin/restore_iptables.sh

echo "Создаю systemd-сервис ss_redsocks.service..."
tee /etc/systemd/system/ss_redsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks + Redsocks Service
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ss_redsocks.sh start
ExecStop=/usr/local/bin/ss_redsocks.sh stop
ExecStopPost=/usr/local/bin/restore_iptables.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Активирую и запускаю сервис ss_redsocks..."
systemctl daemon-reload
systemctl enable ss_redsocks.service
systemctl start ss_redsocks.service

echo "Теперь вы можете управлять сервисом через systemctl. При остановке iptables будет восстановлен."
