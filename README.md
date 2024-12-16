# scripts

curl -o install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

wget -O install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

Откат: systemctl stop shadowsocks.service

Отключение автозагрузки: systemctl disable shadowsocks.service

Включение автозагрузки: systemctl enable shadowsocks.service

Запуск: systemctl start shadowsocks.service
