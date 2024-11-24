#!/bin/bash

# Установка необходимых пакетов
echo "Установка Shadowsocks и Redsocks..."
sudo apt-get update && sudo apt-get install -y shadowsocks-libev redsocks iptables-persistent

# Конфигурация Shadowsocks
echo "Создание конфигурации для Shadowsocks..."
cat <<EOF | sudo tee /etc/shadowsocks-libev/config.json > /dev/null
{
    "server": "$SERVER_IP",
    "server_port": $SERVER_PORT,
    "local_port": 1080,
    "password": "$PASSWORD",
    "method": "chacha20-ietf-poly1305",
    "fast_open": true,
    "timeout": 300
}
EOF

# Конфигурация Redsocks
echo "Создание конфигурации для Redsocks..."
cat <<EOF | sudo tee /etc/redsocks.conf > /dev/null
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

# Скрипт управления ss_redsocks.sh
echo "Создание скрипта управления ss_redsocks.sh..."
cat <<'EOS' | sudo tee /usr/local/bin/ss_redsocks.sh > /dev/null
#!/bin/bash

CONFIG_FILE="/etc/ss_redsocks.conf"

# Загрузка конфигурации
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Ошибка: Конфигурационный файл $CONFIG_FILE не найден."
    exit 1
fi

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
    if sudo netstat -tuln | grep -q ":12345"; then
        echo "Порт 12345 уже занят, освобождаю..."
        sudo pkill -f redsocks
        sleep 1
    fi
    nohup redsocks -c /etc/redsocks.conf &>/var/log/redsocks.log &
}

stop_redsocks() {
    echo "Останавливаю Redsocks..."
    pkill -f redsocks
    sleep 1
}

configure_iptables() {
    echo "Настраиваю iptables..."
    sudo iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN 2>/dev/null
    sudo iptables -t nat -F REDSOCKS 2>/dev/null
    sudo iptables -t nat -X REDSOCKS 2>/dev/null

    sudo iptables -t nat -N REDSOCKS
    sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345
    sudo iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
    echo "iptables настроен."
}

clear_iptables() {
    echo "Сбрасываю правила iptables..."
    sudo iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN 2>/dev/null
    sudo iptables -t nat -F REDSOCKS 2>/dev/null
    sudo iptables -t nat -X REDSOCKS 2>/dev/null
    echo "iptables очищен."
}

restart_redsocks_if_needed() {
    echo "Перезапускаю Redsocks для стабильной работы..."
    stop_redsocks
    start_redsocks
}

start() {
    echo "Запуск Shadowsocks и Redsocks..."
    start_shadowsocks
    start_redsocks
    configure_iptables
    restart_redsocks_if_needed
    echo "Все сервисы запущены."
}

stop() {
    echo "Остановка всех сервисов..."
    stop_redsocks
    clear_iptables
    stop_shadowsocks
    echo "Все сервисы остановлены."
}

restart() {
    stop
    sleep 1
    start
}

main() {
    case "$1" in
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
            echo "Использование: $0 {start|stop|restart}"
            exit 1
            ;;
    esac
}

main "$@"
EOS

# Делаем скрипт исполняемым
sudo chmod +x /usr/local/bin/ss_redsocks.sh

# Настройка сервиса
echo "Создание systemd сервиса ss_redsocks.service..."
cat <<EOF | sudo tee /etc/systemd/system/ss_redsocks.service > /dev/null
[Unit]
Description=Shadowsocks and Redsocks Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ss_redsocks.sh start
ExecStop=/usr/local/bin/ss_redsocks.sh stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка systemd и запуск сервиса
sudo systemctl daemon-reload
sudo systemctl enable ss_redsocks
sudo systemctl start ss_redsocks

echo "Установка завершена. Используйте команды systemctl для управления сервисом."
