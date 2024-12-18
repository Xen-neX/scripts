# scripts

curl -o install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

wget -O install_shadowsocks.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_shadowsocks_clear.sh" && chmod +x install_shadowsocks.sh && sudo ./install_shadowsocks.sh

Откат: systemctl stop shadowsocks.service

Отключение автозагрузки: systemctl disable shadowsocks.service

Включение автозагрузки: systemctl enable shadowsocks.service

Запуск: systemctl start shadowsocks.service

АЛЬТЕРНАТИВНЫЙ ВАРИАНТ, ТОЛЬКО 443 и 80 ПО УМОЛЧАНИЮ

curl -o install_ss_redsocks_clear.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_ss_redsocks_clear.sh" && chmod +x install_ss_redsocks_clear.sh && sudo ./install_ss_redsocks_clear.sh

wget -O install_ss_redsocks_clear.sh "https://raw.githubusercontent.com/Xen-neX/scripts/refs/heads/test/install_ss_redsocks_clear.sh" && chmod +x install_ss_redsocks_clear.sh && sudo ./install_ss_redsocks_clear.sh

Откат: systemctl stop ss_redsocks.service

Отключение автозагрузки: systemctl disable ss_redsocks.service

Включение автозагрузки: systemctl enable ss_redsocks.service

Запуск: systemctl start ss_redsocks.service
