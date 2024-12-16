#!/bin/bash

# Установка Shadowsocks
install_shadowsocks() {
    echo "Установка shadowsocks-libev..."
    sudo apt-get update
    sudo apt-get install -y shadowsocks-libev
    echo "Shadowsocks установлен."
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
    nohup ss-redir -s $SERVER_IP -p $SERVER_PORT -m chacha20-ietf-poly1305 -k $SERVER_PASSWORD -b 127.0.0.1 -l 60080 --no-delay -u -T -v </dev/null &>>/var/log/ss-redir.log &
    sleep 2
    if ! pgrep -f ss-redir > /dev/null; then
        echo "Ошибка: ss-redir не запустился!"
        exit 1
    fi
    echo "ss-redir успешно запущен."
}

stop_ssredir() {
    echo "Остановка ss-redir..."
    pkill -f ss-redir
}

start_iptables() {
    echo "Настройка iptables..."
    [ ! -d /etc/iptables ] && mkdir -p /etc/iptables
    iptables-save > \$IPTABLES_BACKUP

    iptables -t mangle -N SSREDIR 2>/dev/null || echo "Цепочка SSREDIR уже существует."
    iptables -t mangle -A SSREDIR -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR -m mark --mark 0x2333 -j RETURN
    iptables -t mangle -A SSREDIR -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SSREDIR -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR -p udp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR -p tcp --syn -j MARK --set-mark 0x2333
    iptables -t mangle -A SSREDIR -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
    iptables -t mangle -A SSREDIR -j CONNMARK --save-mark
    iptables -t mangle -A PREROUTING -p tcp -j SSREDIR
    iptables -t mangle -A PREROUTING -p udp -j SSREDIR
    iptables -t mangle -A OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
    iptables -t mangle -A PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
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
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    echo "Служба shadowsocks создана."
}

# Основной процесс выполнения
echo "Запускается процесс установки и настройки..."
install_shadowsocks
get_user_input
create_shadowsocks_script
create_systemd_service

# Активируем и запускаем сервис
echo "Активирую и запускаю сервис shadowsocks.service..."
sudo systemctl daemon-reload
sudo systemctl enable shadowsocks.service
sudo systemctl restart shadowsocks.service

echo "Проверка статуса службы shadowsocks.service:"
sudo systemctl status shadowsocks.service
