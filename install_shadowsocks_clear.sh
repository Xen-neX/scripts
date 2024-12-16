#!/bin/bash

# Установка Shadowsocks и его настройка
install_shadowsocks() {
    echo "Установка shadowsocks-libev..."
    sudo apt-get update
    sudo apt-get install -y shadowsocks-libev
}

# Запрос параметров у пользователя
get_user_input() {
    read -p "Введите IP-адрес сервера: " SERVER_IP
    read -p "Введите порт сервера: " SERVER_PORT
    read -p "Введите пароль: " SERVER_PASSWORD
}

# Создание скрипта shadowsocks.sh
create_shadowsocks_script() {
    echo "Создаю скрипт shadowsocks.sh..."
    sudo tee /usr/local/bin/shadowsocks.sh > /dev/null <<EOF
#!/bin/bash

IPTABLES_BACKUP="/etc/iptables/rules.v4.bak"
RESOLVCONF_BACKUP="/etc/resolv.conf.bak"

start_ssredir() {
    echo "Запуск ss-redir..."
    (ss-redir -s $SERVER_IP -p $SERVER_PORT -m chacha20-ietf-poly1305 -k $SERVER_PASSWORD -b 127.0.0.1 -l 60080 --no-delay -u -T -v </dev/null &>>/var/log/ss-redir.log &)
}

stop_ssredir() {
    echo "Остановка ss-redir..."
    pkill -f ss-redir
}

start_iptables() {
    echo "Настройка iptables..."
    iptables-save > \$IPTABLES_BACKUP
    iptables -t mangle -N SSREDIR
    iptables -t mangle -A SSREDIR -p tcp --syn -j MARK --set-mark 0x2333
    iptables -t mangle -A OUTPUT -p tcp -j SSREDIR
}

stop_iptables() {
    echo "Восстановление iptables..."
    iptables-restore < \$IPTABLES_BACKUP
}

start_resolvconf() {
    echo "Настройка resolv.conf..."
    cp /etc/resolv.conf \$RESOLVCONF_BACKUP
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
}

stop_resolvconf() {
    echo "Восстановление resolv.conf..."
    cp \$RESOLVCONF_BACKUP /etc/resolv.conf
}

start() {
    echo "Запуск процесса..."
    start_ssredir
    start_iptables
    start_resolvconf
    echo "Процесс запущен."
}

stop() {
    echo "Остановка процесса..."
    stop_resolvconf
    stop_iptables
    stop_ssredir
    echo "Процесс остановлен."
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) stop && start ;;
    *) echo "Использование: \$0 {start|stop|restart}" ;;
esac
EOF
    sudo chmod +x /usr/local/bin/shadowsocks.sh
    echo "Скрипт shadowsocks.sh создан."
}

# Создание systemd-сервиса
create_systemd_service() {
    echo "Создаю systemd-сервис shadowsocks..."
    sudo tee /etc/systemd/system/shadowsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks Proxy Service
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/shadowsocks.sh start
ExecStop=/usr/local/bin/shadowsocks.sh stop
ExecReload=/usr/local/bin/shadowsocks.sh restart
PIDFile=/run/shadowsocks.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable shadowsocks.service
    echo "Служба shadowsocks создана."
}

# Проверка аргументов
if [ "$1" == "install" ]; then
    install_shadowsocks
    get_user_input
    create_shadowsocks_script
    create_systemd_service
    echo "Запускаю службу shadowsocks..."
    sudo systemctl start shadowsocks
    echo "Проверка статуса службы shadowsocks:"
    sudo systemctl status shadowsocks
else
    echo "Используйте: $0 install"
    echo "После установки команды:"
    echo "  sudo systemctl start shadowsocks"
    echo "  sudo systemctl stop shadowsocks"
    echo "  sudo systemctl restart shadowsocks"
    echo "  sudo systemctl status shadowsocks"
fi
