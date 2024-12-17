#!/bin/bash

# Перед началом: если сервис уже запущен, останавливаем его.
if systemctl is-active --quiet ss_redsocks.service; then
    echo "Обнаружен запущенный сервис ss_redsocks.service. Останавливаю..."
    sudo systemctl stop ss_redsocks.service
    sleep 2 # Даем время сервису остановиться
fi

echo "Устанавливаю необходимые пакеты..."
sudo apt-get update
sudo apt-get install -y shadowsocks-libev redsocks iptables iproute2

# Запрос параметров для Shadowsocks
read -p "Введите IP-адрес Shadowsocks-сервера: " SERVER_IP
read -p "Введите порт Shadowsocks-сервера: " SERVER_PORT
read -p "Введите пароль Shadowsocks: " SERVER_PASSWORD

# Запрос правил перенаправления
echo "Укажите протоколы и порты для перенаправления (например: tcp 443 tcp 80 udp 53)."
echo "Если оставить пустым, будет перенаправляться весь TCP-трафик и только UDP/53 для DNS."
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
    "method": "chacha20-ietf-poly1305", # Или другой метод
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
    dest_ip = 1.1.1.1;
    dest_port = 53;
    udp_timeout = 30;
    udp_timeout_stream = 180;
}

dnstc {
    local_ip = 127.0.0.1;
    local_port = 5300;
}
EOF

echo "Создаю скрипт запуска/остановки /usr/local/bin/ss_redsocks.sh..."
sudo tee /usr/local/bin/ss_redsocks.sh > /dev/null <<EOF
#!/bin/bash

SERVER_IP="$SERVER_IP"
SERVER_PORT="$SERVER_PORT"
CUSTOM_RULES="<span class="math-inline">CUSTOM\_RULES"
SYSTEM\_DNS\=</span>(printf %q "<span class="math-inline">SYSTEM\_DNS"\)
SYSTEM\_DNS\="\\$SYSTEM\_DNS"
start\_shadowsocks\(\) \{
echo "Запускаю Shadowsocks\.\.\."
\(nohup ss\-local \-u \-c /etc/shadowsocks\-libev/config\.json &\>/var/log/shadowsocks\.log &\)
sleep 2
\}
stop\_shadowsocks\(\) \{
echo "Останавливаю Shadowsocks\.\.\."
pkill \-f ss\-local
\}
start\_redsocks\(\) \{
echo "Запускаю Redsocks\.\.\."
\# Проверяем, не запущен ли redsocks уже
if pgrep \-x "redsocks" \>/dev/null; then
echo "Redsocks уже запущен\. Пропускаем запуск\."
return 0
fi
\(nohup redsocks \-c /etc/redsocks\.conf &\>/var/log/redsocks\.log &\)
sleep 2
\}
stop\_redsocks\(\) \{
echo "Останавливаю Redsocks\.\.\."
pkill \-f redsocks
\}
start\_resolvconf\(\) \{
echo "Настраиваю DNS на публичный \(1\.1\.1\.1\)\.\.\."
echo "nameserver 1\.1\.1\.1" \> /etc/resolv\.conf
\}
stop\_resolvconf\(\) \{
echo "Восстанавливаю исходный resolv\.conf\.\.\."
echo "\\$SYSTEM\_DNS" \> /etc/resolv\.conf
\}
configure\_iptables\(\) \{
echo "Настраиваю iptables\.\.\."
YOUR\_SERVER\_IP\=\\$\(hostname \-I \| awk '\{print \\$1\}'\)
sudo iptables \-t nat \-F
sudo iptables \-t nat \-X REDSOCKS 2\>/dev/null
sudo iptables \-t nat \-N REDSOCKS
sudo iptables \-t nat \-A OUTPUT \-p tcp \-d 127\.0\.0\.0/8 \-j RETURN
sudo iptables \-t nat \-A OUTPUT \-p tcp \-d \\$YOUR\_SERVER\_IP \-j RETURN
sudo iptables \-t nat \-A OUTPUT \-p tcp \-d \\$SERVER\_IP \-\-dport \\$SERVER\_PORT \-j RETURN
if \[ \-n "\\$CUSTOM\_RULES" \]; then
PROTO\_PORTS\=\(\\$CUSTOM\_RULES\)
COUNT\=\\$\{\#PROTO\_PORTS\[@\]\}
i\=0
while \[ \\$i \-lt \\$COUNT \]; do
PROTO\=\\$\{PROTO\_PORTS\[\\$i\]\}
PORT\=\\$\{PROTO\_PORTS\[\\$\(\(i\+1\)\)\]\}
i\=\\$\(\(i\+2\)\)
if \[ "\\$PROTO" \= "tcp" \]; then
sudo iptables \-t nat \-A REDSOCKS \-p tcp \-\-dport \\$PORT \-j REDIRECT \-\-to\-ports 12345
elif \[ "\\$PROTO" \= "udp" \]; then
sudo iptables \-t nat \-A REDSOCKS \-p udp \-\-dport \\$PORT \-j REDIRECT \-\-to\-ports 10053
fi
done
sudo iptables \-t nat \-A OUTPUT \-p tcp \-j REDSOCKS
sudo iptables \-t nat \-A OUTPUT \-p udp \-j REDSOCKS
else
\# Весь TCP и только UDP/53
sudo iptables \-t nat \-A REDSOCKS \-p tcp \-j REDIRECT \-\-to\-ports 12345
sudo iptables \-t nat \-A OUTPUT \-p tcp \-j REDSOCKS
sudo iptables \-t nat \-A REDSOCKS \-p udp \-\-dport 53 \-j REDIRECT \-\-to\-ports 10053
sudo iptables \-t nat \-A OUTPUT \-p udp \-\-dport 53 \-j REDSOCKS
fi
\}
clear\_iptables\(\) \{
echo "Очищаю iptables\.\.\."
sudo iptables \-t nat \-F REDSOCKS 2\>/dev/null
sudo iptables \-t nat \-X REDSOCKS 2\>/dev/null
sudo iptables \-t nat \-F 2\>/dev/null
\}
start\(\) \{
start\_shadowsocks
start\_redsocks
sleep 3
configure\_iptables
start\_resolvconf
echo "Все сервисы запущены\."
\}
stop\(\) \{
clear\_iptables
stop\_resolvconf
stop\_shadowsocks
stop\_redsocks
echo "Все сервисы остановлены и iptables восстановлен\."
\}
restart\(\) \{
stop
sleep 1
start
\}
main\(\) \{
case "\\$1" in
start\)
start
;;
stop\)
stop
;;
restart\)
restart
;;
\*\)
echo "Использование\: \\$0 \{start\|stop\|restart\}"
exit 1
;;
esac
\}
main "</span>@"
EOF

sudo chmod +x /usr/local/bin/ss_redsocks.sh

echo "Создаю systemd-сервис ss_redsocks.service
