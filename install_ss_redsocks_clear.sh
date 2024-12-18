#!/bin/bash

echo "Устанавливаю необходимые пакеты..."
sudo apt-get update
sudo apt-get install -y shadowsocks-libev redsocks

# Запрос параметров от пользователя
read -p "Введите IP-адрес Shadowsocks-сервера: " SERVER_IP
read -p "Введите порт Shadowsocks-сервера: " SERVER_PORT
read -p "Введите пароль Shadowsocks: " SERVER_PASSWORD

# Запрос пользовательских правил перенаправления (по аналогии с TPROXY скриптом)
# Формат: tcp 443 tcp 80 udp 12345
# Пустой ввод = использовать порты 80 и 443 по умолчанию
echo "Укажите протоколы и порты для перенаправления (например: tcp 443 tcp 80 udp 12345)."
echo "Если оставить пустым, будут использованы порты 80 и 443 (TCP)."
read -p "Протоколы и порты: " CUSTOM_RULES

# Сохраняем текущий DNS
SYSTEM_DNS="$(cat /etc/resolv.conf)"

echo "Создаю конфигурацию Shadowsocks..."
sudo tee /etc/shadowsocks-libev/config.json > /dev/null <<EOF
{
    "server": "$SERVER_IP",
    "server_port": $SERVER_PORT,
    "local_port": 1080,
    "password": "$SERVER_PASSWORD",
    "method": "chacha20-ietf-poly1305",
    "mode": "tcp_and_udp",
    "fast_open": true,
    "no_delay": true,
    "mptcp": true,
    "reuse_port": true
}
EOF

echo "Создаю конфигурацию Redsocks..."
sudo tee /etc/redsocks.conf > /dev/null <<EOF
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

echo "Создаю скрипт для запуска Shadowsocks и Redsocks..."
sudo tee /usr/local/bin/ss_redsocks.sh > /dev/null <<EOF
#!/bin/bash

SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
CUSTOM_RULES="$CUSTOM_RULES"
SYSTEM_DNS=$(printf %q "$SYSTEM_DNS")
SYSTEM_DNS="\$SYSTEM_DNS"

start_shadowsocks() {
    echo "Запускаю Shadowsocks..."
    (nohup ss-local -c /etc/shadowsocks-libev/config.json &>/var/log/shadowsocks.log &)
}

stop_shadowsocks() {
    echo "Останавливаю Shadowsocks..."
    pkill -f ss-local
}

start_redsocks() {
    echo "Запускаю Redsocks..."
    (nohup redsocks -c /etc/redsocks.conf &>/var/log/redsocks.log &)
}

stop_redsocks() {
    echo "Останавливаю Redsocks..."
    pkill -f redsocks
}

start_resolvconf() {
    echo "Настраиваю resolv.conf на публичный DNS..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
}

stop_resolvconf() {
    echo "Восстанавливаю исходный resolv.conf..."
    echo "\$SYSTEM_DNS" > /etc/resolv.conf
}

configure_iptables() {
    echo "Настраиваю iptables..."
    YOUR_SERVER_IP=\$(hostname -I | awk '{print \$1}')

    /usr/sbin/iptables -t nat -F
    /usr/sbin/iptables -t nat -N REDSOCKS 2>/dev/null

    # Исключаем локальный трафик и трафик к Shadowsocks-серверу
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d \$YOUR_SERVER_IP -j RETURN
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -d \$SERVER_IP --dport \$SERVER_PORT -j RETURN

    if [ -n "\$CUSTOM_RULES" ]; then
        # Пользовательские правила
        PROTO_PORTS=(\$CUSTOM_RULES)
        COUNT=\${#PROTO_PORTS[@]}
        i=0
        while [ \$i -lt \$COUNT ]; do
            PROTO=\${PROTO_PORTS[\$i]}
            PORT=\${PROTO_PORTS[\$((i+1))]}
            i=\$((i+2))

            # Для tcp
            if [ "\$PROTO" = "tcp" ]; then
                /usr/sbin/iptables -t nat -A REDSOCKS -p tcp --dport \$PORT -j REDIRECT --to-ports 12345
            elif [ "\$PROTO" = "udp" ]; then
                # Для udp redsocks обычно не перехватывает все порты, но мы можем для примера сделать то же самое:
                # Однако TPROXY обычно использовался для udp. Redsocks для udp ограниченно работает, но оставим как есть.
                /usr/sbin/iptables -t nat -A REDSOCKS -p udp --dport \$PORT -j REDIRECT --to-ports 12345
            fi
        done
    else
        # Старое поведение, если пользователь не ввел ничего
        /usr/sbin/iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
        /usr/sbin/iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345
    fi

    # Перенаправляем остальной TCP трафик через REDSOCKS
    /usr/sbin/iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
}

clear_iptables() {
    echo "Очищаю iptables..."
    /usr/sbin/iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -F REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -X REDSOCKS 2>/dev/null
    /usr/sbin/iptables -t nat -F 2>/dev/null
}

start() {
    start_shadowsocks
    start_redsocks
    configure_iptables
    start_resolvconf
    echo "Все сервисы запущены."
}

stop() {
    # СНАЧАЛА очищаем правила iptables
    clear_iptables

    # ПОТОМ восстанавливаем DNS
    stop_resolvconf

    # ПОТОМ останавливаем сервисы
    stop_shadowsocks
    stop_redsocks

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

sudo chmod +x /usr/local/bin/ss_redsocks.sh

echo "Создаю systemd-сервис..."
sudo tee /etc/systemd/system/ss_redsocks.service > /dev/null <<EOF
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

echo "Активирую и запускаю сервис ss_redsocks..."
sudo systemctl daemon-reload
sudo systemctl enable ss_redsocks.service
sudo systemctl start ss_redsocks.service

echo "Проверка статуса:"
sudo systemctl status ss_redsocks.service
