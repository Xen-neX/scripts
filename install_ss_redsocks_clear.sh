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
    # Проверка и освобождение порта
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
    # Удаляем предыдущие правила, если они существуют
    sudo iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN 2>/dev/null
    sudo iptables -t nat -F REDSOCKS 2>/dev/null
    sudo iptables -t nat -X REDSOCKS 2>/dev/null

    # Создаём цепочку REDSOCKS
    sudo iptables -t nat -N REDSOCKS

    # Исключения для локального трафика
    sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN
    sudo iptables -t nat -A OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN

    # Перенаправление HTTP и HTTPS
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 80 -j REDIRECT --to-ports 12345
    sudo iptables -t nat -A REDSOCKS -p tcp --dport 443 -j REDIRECT --to-ports 12345

    # Общий трафик через REDSOCKS
    sudo iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

    echo "iptables настроен."
}

clear_iptables() {
    echo "Сбрасываю правила iptables..."
    # Удаляем правила, связанные с REDSOCKS
    sudo iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d $(hostname -I | awk '{print $1}') -j RETURN 2>/dev/null
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.0/8 -j RETURN 2>/dev/null

    # Удаляем цепочку REDSOCKS
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
