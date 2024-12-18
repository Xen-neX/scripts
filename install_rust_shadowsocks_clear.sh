#!/bin/bash
echo "Версия 2.0.0 - Shadowsocks-rust edition - полное прозрачное проксирование всего трафика или выбор портов + восстановление системного днс при stop и переустановке + --reuse-port"
# Проверяем, запущена ли служба shadowsocks.service
if systemctl is-active --quiet shadowsocks.service; then
    echo "shadowsocks.service активен. Останавливаю, чтобы восстановить системный DNS..."
    sudo systemctl stop shadowsocks.service
fi

# Теперь, когда служба остановлена (или не была запущена),
# резольв должен быть системным. Сохраняем системный DNS.
SYSTEM_DNS="$(cat /etc/resolv.conf)"

echo "Устанавливаю shadowsocks-rust..."
# Создаем временную директорию для загрузки
TMP_DIR=$(mktemp -d)
cd $TMP_DIR

# Определяем архитектуру системы
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_NAME="x86_64-unknown-linux-gnu"
        ;;
    aarch64)
        ARCH_NAME="aarch64-unknown-linux-gnu"
        ;;
    *)
        echo "Неподдерживаемая архитектура: $ARCH"
        exit 1
        ;;
esac

# Загружаем последнюю версию shadowsocks-rust
LATEST_VERSION=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
wget "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VERSION}/shadowsocks-${LATEST_VERSION}.${ARCH_NAME}.tar.xz"
tar -xf "shadowsocks-${LATEST_VERSION}.${ARCH_NAME}.tar.xz"

# Устанавливаем бинарные файлы
sudo mv ssserver /usr/local/bin/
sudo mv sslocal /usr/local/bin/
sudo mv ssurl /usr/local/bin/
sudo mv ssmanager /usr/local/bin/
sudo mv ssservice /usr/local/bin/

# Очищаем временную директорию
cd - > /dev/null
rm -rf $TMP_DIR

# Запрос параметров у пользователя
read -p "Введите IP-адрес сервера: " SERVER_IP
read -p "Введите порт сервера: " SERVER_PORT
read -p "Введите пароль: " SERVER_PASSWORD

# Запрос пользовательских правил перенаправления
echo "Укажите протоколы и порты, которые необходимо перенаправить через shadowsocks."
echo "Формат: tcp 443 tcp 80 udp 12345"
echo "Если оставить пустым (нажать Enter), то будет перенаправлен весь трафик"
read -p "Протоколы и порты: " CUSTOM_RULES

# Создание скрипта shadowsocks.sh
echo "Создаю скрипт shadowsocks.sh..."
sudo tee /usr/local/bin/shadowsocks.sh > /dev/null <<EOF
#!/bin/bash

SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
SERVER_PASSWORD="$SERVER_PASSWORD"
CUSTOM_RULES="$CUSTOM_RULES"
SYSTEM_DNS=$(printf %q "$SYSTEM_DNS")
SYSTEM_DNS="\$SYSTEM_DNS"

start_sslocal() {
    echo "Запускаю sslocal..."
    (sslocal -s "\$SERVER_IP:\$SERVER_PORT" -m "chacha20-ietf-poly1305" -k "\$SERVER_PASSWORD" --tcp-redir "127.0.0.1:60080" --udp-redir "127.0.0.1:60080" -U --reuse-port </dev/null &>>/var/log/sslocal.log &)
}

stop_sslocal() {
    echo "Останавливаю sslocal..."
    kill -9 \$(pidof sslocal) &>/dev/null
}

start_iptables() {
    echo "Настраиваю iptables..."
    iptables -t mangle -N SSREDIR 2>/dev/null
    iptables -t mangle -F SSREDIR
    iptables -t mangle -D OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR 2>/dev/null
    iptables -t mangle -D OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR 2>/dev/null
    iptables -t mangle -D PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR 2>/dev/null
    iptables -t mangle -D PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR 2>/dev/null
    iptables -t mangle -F SSREDIR
    iptables -t mangle -X SSREDIR
    iptables -t mangle -N SSREDIR

    iptables -t mangle -A SSREDIR -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR -m mark --mark 0x2333 -j RETURN
    # Исключаем сам Shadowsocks сервер
    iptables -t mangle -A SSREDIR -p tcp -d \$SERVER_IP --dport \$SERVER_PORT -j RETURN
    iptables -t mangle -A SSREDIR -p udp -d \$SERVER_IP --dport \$SERVER_PORT -j RETURN
    # Исключаем локальный трафик
    iptables -t mangle -A SSREDIR -d 127.0.0.0/8 -j RETURN

    if [ -n "\$CUSTOM_RULES" ]; then
        PROTO_PORTS=(\$CUSTOM_RULES)
        COUNT=\${#PROTO_PORTS[@]}
        i=0
        while [ \$i -lt \$COUNT ]; do
            PROTO=\${PROTO_PORTS[\$i]}
            PORT=\${PROTO_PORTS[\$((i+1))]}
            i=\$((i+2))

            if [ "\$PROTO" = "tcp" ]; then
                iptables -t mangle -A SSREDIR -p tcp --dport \$PORT -j MARK --set-mark 0x2333
            elif [ "\$PROTO" = "udp" ]; then
                iptables -t mangle -A SSREDIR -p udp --dport \$PORT -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
            fi
        done
    else
        # Старое поведение — перенаправляем весь TCP/UDP трафик
        iptables -t mangle -A SSREDIR -p tcp --syn -j MARK --set-mark 0x2333
        iptables -t mangle -A SSREDIR -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
    fi

    iptables -t mangle -A SSREDIR -j CONNMARK --save-mark

    # Применяем правила для локального (OUTPUT) и не-локального (PREROUTING) трафика
    iptables -t mangle -A OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR

    # Применяем TPROXY
    iptables -t mangle -A PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
    iptables -t mangle -A PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
}

stop_iptables() {
    echo "Очищаю iptables..."
    iptables -t mangle -F SSREDIR &>/dev/null
    iptables -t mangle -X SSREDIR &>/dev/null
}

start_iproute2() {
    echo "Настраиваю iproute2..."
    ip route add local default dev lo table 100 2>/dev/null
    ip rule add fwmark 0x2333 table 100 2>/dev/null
}

stop_iproute2() {
    echo "Очищаю iproute2..."
    ip rule del table 100 &>/dev/null
    ip route flush table 100 &>/dev/null
}

start_resolvconf() {
    echo "Настраиваю resolv.conf..."
    echo "nameserver 1.1.1.1" >/etc/resolv.conf
}

stop_resolvconf() {
    echo "Восстанавливаю resolv.conf..."
    # Восстанавливаем исходное значение DNS
    echo "\$SYSTEM_DNS" > /etc/resolv.conf
}

start() {
    echo "Запуск процесса..."
    start_sslocal
    start_iptables
    start_iproute2
    start_resolvconf
    echo "Процесс запущен."
}

stop() {
    echo "Остановка процесса..."
    stop_resolvconf
    stop_iproute2
    stop_iptables
    stop_sslocal
    echo "Процесс остановлен."
}

restart() {
    echo "Перезапуск процесса..."
    stop
    sleep 1
    start
}

main() {
    echo "Переданы аргументы: \$@"
    if [ \$# -eq 0 ]; then
        echo "usage: \$0 start|stop|restart ..."
        exit 1
    fi

    for funcname in "\$@"; do
        if declare -F "\$funcname" > /dev/null; then
            echo "Выполняется функция: \$funcname"
            \$funcname
        else
            echo "Ошибка: '\$funcname' не является shell-функцией"
            exit 1
        fi
    done
}

main "\$@"
EOF

# Делаем скрипт исполняемым
sudo chmod +x /usr/local/bin/shadowsocks.sh

# Создание systemd-сервиса
echo "Создаю systemd-сервис для shadowsocks.sh..."
sudo tee /etc/systemd/system/shadowsocks.service > /dev/null <<EOF
[Unit]
Description=Shadowsocks Rust Custom Script
After=network.target

[Service]
ExecStart=/usr/local/bin/shadowsocks.sh start
ExecStop=/usr/local/bin/shadowsocks.sh stop
Restart=on-failure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Активируем и запускаем сервис
echo "Активирую и запускаю сервис shadowsocks.service..."
sudo systemctl daemon-reload
sudo systemctl enable shadowsocks.service
sudo systemctl start shadowsocks.service

# Проверка статуса
echo "Сервис shadowsocks.service запущен. Проверяю статус..."
sudo systemctl status shadowsocks.service
