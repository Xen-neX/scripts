#!/bin/bash

# Установка shadowsocks-libev
echo "Устанавливаю shadowsocks-libev..."
sudo apt-get update
sudo apt-get install -y shadowsocks-libev

# Запрос параметров у пользователя
read -p "Введите IP-адрес сервера: " SERVER_IP
read -p "Введите порт сервера: " SERVER_PORT
read -p "Введите пароль: " SERVER_PASSWORD

# Создание скрипта shadowsocks.sh
echo "Создаю скрипт shadowsocks.sh..."
sudo bash -c "cat > /usr/local/bin/shadowsocks.sh <<EOF
#!/bin/bash

start_ssredir() {
    (ss-redir -s $SERVER_IP -p $SERVER_PORT -m chacha20-ietf-poly1305 -k $SERVER_PASSWORD -b 127.0.0.1 -l 60080 --no-delay -u -T -v </dev/null &>>/var/log/ss-redir.log &)
}

stop_ssredir() {
    kill -9 \$(pidof ss-redir) &>/dev/null
}

start_iptables() {
    iptables -t mangle -N SSREDIR
    iptables -t mangle -A SSREDIR -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR -m mark --mark 0x2333 -j RETURN
    iptables -t mangle -A SSREDIR -p tcp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR -p udp -d $SERVER_IP --dport $SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SSREDIR -p tcp --syn -j MARK --set-mark 0x2333
    iptables -t mangle -A SSREDIR -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
    iptables -t mangle -A SSREDIR -j CONNMARK --save-mark
    iptables -t mangle -A OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
    iptables -t mangle -A PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
}

stop_iptables() {
    iptables -t mangle -F SSREDIR &>/dev/null
    iptables -t mangle -X SSREDIR &>/dev/null
}

start_iproute2() {
    ip route add local default dev lo table 100
    ip rule add fwmark 0x2333 table 100
}

stop_iproute2() {
    ip rule del table 100 &>/dev/null
    ip route flush table 100 &>/dev/null
}

start_resolvconf() {
    echo "nameserver 1.1.1.1" >/etc/resolv.conf
}

stop_resolvconf() {
    echo "nameserver 114.114.114.114" >/etc/resolv.conf
}

start() {
    echo "start ..."
    start_ssredir
    start_iptables
    start_iproute2
    start_resolvconf
    echo "start end"
}

stop() {
    echo "stop ..."
    stop_resolvconf
    stop_iproute2
    stop_iptables
    stop_ssredir
    echo "stop end"
}

restart() {
    stop
    sleep 1
    start
}

main() {
    if [ \$# -eq 0 ]; then
        echo "usage: \$0 start|stop|restart ..."
        return 1
    fi

    for funcname in \"\$@\"; do
        if [ \"\$(type -t \$funcname)\" != \"function\" ]; then
            echo \"'\$funcname' not a shell function\"
            return 1
        fi
    done

    for funcname in \"\$@\"; do
        \$funcname
    done
    return 0
}
main \"\$@\"
EOF"

# Делаем скрипт исполняемым
sudo chmod +x /usr/local/bin/shadowsocks.sh

# Создание systemd-сервиса
echo "Создаю systemd-сервис для shadowsocks.sh..."
sudo bash -c "cat > /etc/systemd/system/shadowsocks.service <<EOF
[Unit]
Description=Shadowsocks Custom Script
After=network.target

[Service]
ExecStart=/usr/local/bin/shadowsocks.sh start
ExecStop=/usr/local/bin/shadowsocks.sh stop
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"

# Активируем и запускаем сервис
echo "Активирую и запускаю сервис shadowsocks.service..."
sudo systemctl daemon-reload
sudo systemctl enable shadowsocks.service
sudo systemctl start shadowsocks.service

# Проверка статуса
echo "Сервис shadowsocks.service запущен. Проверяю статус..."
sudo systemctl status shadowsocks.service
