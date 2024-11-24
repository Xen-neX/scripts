#!/bin/bash

echo "Установка необходимых пакетов..."
sudo apt-get update
sudo apt-get install -y shadowsocks-libev redsocks iptables-persistent

echo "Введите настройки для Shadowsocks:"
read -p "Введите IP-адрес прокси-сервера (SERVER_IP): " SERVER_IP
read -p "Введите порт прокси-сервера (SERVER_PORT): " SERVER_PORT
read -p "Введите пароль прокси-сервера (SERVER_PASSWORD): " SERVER_PASSWORD

echo "Введите настройки для Redsocks:"
read -p "Введите локальный порт для Redsocks (REDSOCKS_PORT, обычно 12345): " REDSOCKS_PORT

echo "Создание конфигурации для Shadowsocks..."
SHADOWSOCKS_CONFIG="/etc/shadowsocks-libev/config.json"
cat <<EOF | sudo tee $SHADOWSOCKS_CONFIG
{
    "server": "$SERVER_IP",
    "server_port": $SERVER_PORT,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "$SERVER_PASSWORD",
    "timeout": 300,
    "method": "chacha20-ietf-poly1305",
    "fast_open": true
}
EOF

echo "Создание конфигурации для Redsocks..."
REDSOCKS_CONFIG="/etc/redsocks.conf"
cat <<EOF | sudo tee $REDSOCKS_CONFIG
base {
    log = "file:/var/log/redsocks.log";
    daemon = on;
    user = redsocks;
    group = redsocks;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDSOCKS_PORT;
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

echo "Создание скрипта управления ss_redsocks.sh..."
SS_REDSOCKS_SCRIPT="/usr/local/bin/ss_redsocks.sh"
cat <<'EOF' | sudo tee $SS_REDSOCKS_SCRIPT
#!/bin/bash

SHADOWSOCKS_CONFIG="/etc/shadowsocks-libev/config.json"
REDSOCKS_CONFIG="/etc/redsocks.conf"
SERVER_IP=$(jq -r .server $SHADOWSOCKS_CONFIG)
SERVER_PORT=$(jq -r .server_port $SHADOWSOCKS_CONFIG)
REDSOCKS_PORT=$(grep local_port $REDSOCKS_CONFIG | head -n 1 | awk '{print $3}' | tr -d ';')

start_iptables() {
    echo "Настройка iptables..."
    sudo iptables -t nat -F REDSOCKS 2>/dev/null || sudo iptables -t nat -N REDSOCKS
    sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d "$SERVER_IP" -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d "$SERVER_IP" --dport "$SERVER_PORT" -j RETURN
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports "$REDSOCKS_PORT"
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports "$REDSOCKS_PORT"
    sudo iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
}

stop_iptables() {
    echo "Очистка правил iptables..."
    sudo iptables -t nat -F REDSOCKS
    sudo iptables -t nat -X REDSOCKS
}

start() {
    echo "Запуск Shadowsocks и Redsocks..."
    sudo systemctl restart shadowsocks-libev
    sudo systemctl restart redsocks
    start_iptables
    echo "Сервисы запущены."
}

stop() {
    echo "Остановка Shadowsocks и Redsocks..."
    sudo systemctl stop redsocks
    sudo systemctl stop shadowsocks-libev
    stop_iptables
    echo "Сервисы остановлены."
}

restart() {
    stop
    start
}

status() {
    echo "Состояние сервисов:"
    sudo systemctl status shadowsocks-libev
    sudo systemctl status redsocks
}

main() {
    case "$1" in
        start) start ;;
        stop) stop ;;
        restart) restart ;;
        status) status ;;
        *) echo "Использование: $0 {start|stop|restart|status}" ;;
    esac
}

main "$@"
EOF
sudo chmod +x $SS_REDSOCKS_SCRIPT

echo "Создание systemd сервиса ss_redsocks.service..."
SS_REDSOCKS_SERVICE="/etc/systemd/system/ss_redsocks.service"
cat <<EOF | sudo tee $SS_REDSOCKS_SERVICE
[Unit]
Description=Shadowsocks + Redsocks Service
After=network.target

[Service]
ExecStart=$SS_REDSOCKS_SCRIPT start
ExecStop=$SS_REDSOCKS_SCRIPT stop
ExecReload=$SS_REDSOCKS_SCRIPT restart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ss_redsocks.service
sudo systemctl start ss_redsocks.service

echo "Установка завершена. Используйте команды systemctl для управления сервисом ss_redsocks.service."
