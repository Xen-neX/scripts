#!/bin/bash

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root"
    exit 1
fi

# Установка зависимостей
apt update
apt install -y wget curl iptables

# Создание директорий
mkdir -p /etc/shadowsocks-rust/

# Загрузка и установка shadowsocks-rust
wget https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.21.2/shadowsocks-v1.21.2.x86_64-unknown-linux-gnu.tar.xz
tar -xf shadowsocks-v1.21.2.x86_64-unknown-linux-gnu.tar.xz
mv sslocal /usr/bin/
mv ssserver /usr/bin/
mv ssmanager /usr/bin/
mv ssurl /usr/bin/
rm shadowsocks-v1.21.2.x86_64-unknown-linux-gnu.tar.xz

# Создание конфигурационного файла
cat > /etc/shadowsocks-rust/config.json << EOF
{
    "server": "158.255.214.188",
    "server_port": 443,
    "password": "RP3vtbRmc6JTLXyFwLR2dm",
    "method": "chacha20-ietf-poly1305",
    "local_address": "0.0.0.0",
    "local_port": 1082,
    "mode": "tcp_and_udp"
}
EOF

# Очистка существующих правил
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X
iptables -t mangle -X

# Настройка iptables для прозрачного проксирования
iptables -t nat -N SHADOWSOCKS
iptables -t nat -A SHADOWSOCKS -d 158.255.214.188 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -p tcp -j REDIRECT --to-port 1082
iptables -t nat -A OUTPUT -p tcp -j SHADOWSOCKS
iptables -t nat -A PREROUTING -p tcp -j SHADOWSOCKS

# Создание systemd сервиса
cat > /etc/systemd/system/shadowsocks-rust.service << EOF
[Unit]
Description=Shadowsocks-rust Client Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/sslocal -c /etc/shadowsocks-rust/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Сохранение правил iptables
mkdir -p /etc/iptables/
iptables-save > /etc/iptables/rules.v4

# Создание скрипта для восстановления правил iptables
cat > /etc/network/if-pre-up.d/iptables << EOF
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4
exit 0
EOF

chmod +x /etc/network/if-pre-up.d/iptables

# Запуск и включение сервиса
systemctl daemon-reload
