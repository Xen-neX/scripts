# scripts

curl -o install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/main/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

wget -O install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/main/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

Откат: systemctl stop shadowsocks.service

Отключение автозагрузки: systemctl disable shadowsocks.service

Включение автозагрузки: systemctl enable shadowsocks.service

Запуск: systemctl start shadowsocks.service

АЛЬТЕРНАТИВНЫЙ ВАРИАНТ, ТОЛЬКО 443 и 80 ПО УМОЛЧАНИЮ

curl -o install_ss_redsocks_clear.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/main/install_ss_redsocks_clear.sh" && chmod +x install_ss_redsocks_clear.sh && sudo ./install_ss_redsocks_clear.sh

wget -O install_ss_redsocks_clear.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/main/install_ss_redsocks_clear.sh" && chmod +x install_ss_redsocks_clear.sh && sudo ./install_ss_redsocks_clear.sh

Откат: systemctl stop ss_redsocks.service

Отключение автозагрузки: systemctl disable ss_redsocks.service

Включение автозагрузки: systemctl enable ss_redsocks.service

Запуск: systemctl start ss_redsocks.service


{"server":"158.255.214.188","server_port":443,"password":"","method":"chacha20-ietf-poly1305","local_address":"0.0.0.0","local_port":60080,"protocol":"redir","tcp_redir":"redirect","udp_redir":"tproxy","mode":"tcp_and_udp"}
