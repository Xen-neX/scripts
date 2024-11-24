#!/bin/bash

# Установка необходимых пакетов
echo "Устанавливаю необходимые пакеты..."
sudo apt-get update
sudo apt-get install -y shadowsocks-libev redsocks

# Запрос параметров от пользователя
read -p "Введите IP-адрес Shadowsocks-сервера: " SERVER_IP
read -p "Введите порт Shadowsocks-сервера: " SERVER_PORT
read -p "Введите пароль Shadowsocks: " SERVER_PASSWORD

# Создание конфигурационного файла Shadowsocks
echo "Создаю конфигурацию Shadowsocks..."
sudo tee /etc/shadowsocks-libev/config.json > /dev/null <<EOF
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

# Создание скрипта для запуска Shadowsocks и Redsocks
echo "Создаю скрипт для запуска Shadowsocks и Redsocks..."
sudo tee /usr/local/bin/ss_redsocks.sh > /dev/null <<EOF
#!/bin/bash

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

    sudo iptables -t nat -F
    sudo iptables -t nat -N REDSOCKS
    sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d \$YOUR_SERVER_IP -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345
    sudo iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
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
    sudo iptables -t nat -F
    echo "Все сервисы остановлены."
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

# Делаем скрипт исполняемым
sudo chmod +x /usr/local/bin/ss_redsocks.sh

# Создание systemd-сервиса
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

# Перезагрузка systemd, активация и запуск сервиса
echo "Активирую и запускаю сервис ss_redsocks..."
sudo systemctl daemon-reload
sudo systemctl enable ss_redsocks.service
sudo systemctl start ss_redsocks.service

# Проверка статуса
sudo systemctl status ss_redsocks.service

