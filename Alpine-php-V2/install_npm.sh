#!/bin/sh

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

NGINX_CONF_DIR=/etc/nginx/http.d
PHP_FPM_SOCK="127.0.0.1:9000"

# ══════════════════════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════════════════════

domain_exists() {
    [ -f "$NGINX_CONF_DIR/$1.conf" ]
}

load_email() {
    if [ -f /etc/npm_admin_email ]; then
        ADMIN_EMAIL=$(cat /etc/npm_admin_email)
    else
        ADMIN_EMAIL=""
    fi
}

choose_site_type() {
    echo ""
    echo -e "${BLUE}请选择站点类型：${PLAIN}"
    echo "  1) PHP 普通站点"
    echo "  2) PHP + 伪静态（Typecho / WordPress）"
    echo "  3) 反向代理（转发到本地端口）"
    echo ""
    while true; do
        read -p "请输入序号 [1-3]: " type_choice
        case "$type_choice" in
            1) SITE_TYPE=php;         break ;;
            2) SITE_TYPE=php_rewrite; break ;;
            3) SITE_TYPE=proxy;       break ;;
            *) echo -e "${RED}无效输入，请重新选择${PLAIN}" ;;
        esac
    done
}

create_nginx_conf() {
    local domains="$1"   # 空格分隔多域名
    local site_dir="$2"
    local site_type="$3"
    local proxy_port="$4"
    local use_ssl="${5:-1}"
    # 配置文件以第一个域名命名
    local first_domain=$(echo "$domains" | awk '{print $1}')
    local conf_file="$NGINX_CONF_DIR/$first_domain.conf"

    # SSL 块内容
    if [ "$use_ssl" = "1" ]; then
        ssl_listen="listen 443 ssl;
    listen [::]:443 ssl;"
        ssl_cert="
    ssl_certificate /etc/letsencrypt/live/$first_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$first_domain/privkey.pem;"
        http_block="server {
    listen 80;
    listen [::]:80;
    server_name $domains;
    return 301 https://\$host\$request_uri;
}"
    else
        ssl_listen="listen 80;
    listen [::]:80;"
        ssl_cert=""
        http_block=""
    fi

    case "$site_type" in
        php)
            cat > "$conf_file" <<EOF
server {
    $ssl_listen
    server_name $domains;
    root $site_dir;
    index index.php index.html;
$ssl_cert

    location ~ \.php\$ {
        fastcgi_pass $PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
$http_block
EOF
            ;;
        php_rewrite)
            cat > "$conf_file" <<EOF
server {
    $ssl_listen
    server_name $domains;
    root $site_dir;
    index index.php index.html;
$ssl_cert

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        fastcgi_pass $PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
$http_block
EOF
            ;;
        proxy)
            cat > "$conf_file" <<EOF
server {
    $ssl_listen
    server_name $domains;
$ssl_cert

    location / {
        proxy_pass http://127.0.0.1:$proxy_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
$http_block
EOF
            ;;
        v2ray)
            cat > "$conf_file" <<EOF
server {
    $ssl_listen
    server_name $domains;
$ssl_cert

    location $proxy_port {
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
$http_block
EOF
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════
#  1) 添加主机
# ══════════════════════════════════════════════════════════════

add_host() {
    echo -e "${BLUE}=== 添加主机 ===${PLAIN}"

    # 第一步：填域名（支持多个，空格分隔）
    echo -e "${YELLOW}多个域名用空格分隔，例: 995566.xyz www.995566.xyz${PLAIN}"
    while true; do
        read -p "请输入域名: " domain_input
        [ -n "$domain_input" ] && break
        echo -e "${RED}域名不能为空！${PLAIN}"
    done
    first_domain=$(echo "$domain_input" | awk '{print $1}')

    if domain_exists "$first_domain"; then
        echo -e "${RED}域名 $first_domain 已存在！${PLAIN}"
        return 1
    fi

    # 第二步：选站点类型
    choose_site_type

    # 第三步：填目录或端口
    if [ "$SITE_TYPE" = "proxy" ]; then
        while true; do
            read -p "请输入转发端口: " proxy_port
            echo "$proxy_port" | grep -qE '^[0-9]+$' && break
            echo -e "${RED}端口必须为数字！${PLAIN}"
        done
        site_dir=""
    else
        read -p "请输入网站目录 (默认 /home/www/$first_domain): " site_dir
        site_dir=${site_dir:-/home/www/$first_domain}
        mkdir -p "$site_dir"
        chmod 777 "$site_dir"
    fi

    # 第四步：是否申请 HTTPS
    read -p "是否申请 SSL 证书(HTTPS)? (y/n): " apply_cert
    USE_SSL=0
    if [ "$apply_cert" = "y" ]; then
        if [ -z "$ADMIN_EMAIL" ]; then
            while true; do
                read -p "请输入管理邮箱: " ADMIN_EMAIL
                [ -n "$ADMIN_EMAIL" ] && break
                echo -e "${RED}邮箱不能为空！${PLAIN}"
            done
            echo "$ADMIN_EMAIL" > /etc/npm_admin_email
        fi
        echo -e "${GREEN}正在申请 SSL 证书...${PLAIN}"
        d_args=""
        for d in $domain_input; do d_args="$d_args -d $d"; done
        certbot certonly --nginx $d_args --non-interactive --agree-tos -m "$ADMIN_EMAIL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}证书申请失败！${PLAIN}"
            read -p "是否继续以 HTTP 方式添加主机? (y/n): " cont
            [ "$cont" != "y" ] && return 1
        else
            USE_SSL=1
        fi
    fi

    # 生成 Nginx 配置
    if [ "$SITE_TYPE" = "proxy" ]; then
        create_nginx_conf "$domain_input" "" "proxy" "$proxy_port" "$USE_SSL"
    else
        create_nginx_conf "$domain_input" "$site_dir" "$SITE_TYPE" "" "$USE_SSL"
    fi

    nginx -t && rc-service nginx reload
    echo -e "${GREEN}主机 $domain_input 添加完成！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  2) 申请/续期证书（支持多域名）
# ══════════════════════════════════════════════════════════════

cert_apply() {
    echo -e "${BLUE}=== 申请/续期证书 ===${PLAIN}"

    if [ -z "$ADMIN_EMAIL" ]; then
        while true; do
            read -p "请输入管理邮箱: " ADMIN_EMAIL
            [ -n "$ADMIN_EMAIL" ] && break
            echo -e "${RED}邮箱不能为空！${PLAIN}"
        done
        echo "$ADMIN_EMAIL" > /etc/npm_admin_email
    fi

    # 显示已有证书
    cert_list=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README)
    if [ -n "$cert_list" ]; then
        echo -e "${BLUE}已有证书：${PLAIN}"
        echo "$cert_list" | nl -w2 -s') '
        echo ""
        echo -e "${BLUE}操作类型：${PLAIN}"
        echo "  1) 申请新证书"
        echo "  2) 追加域名到现有证书"
        echo "  3) 续期所有证书"
        read -p "请选择 [1-3]: " cert_action
    else
        cert_action=1
    fi

    case "$cert_action" in
        1)
            echo -e "${YELLOW}多个域名用空格分隔，例: a.com b.com${PLAIN}"
            read -p "请输入域名: " domain_input
            [ -z "$domain_input" ] && echo -e "${RED}域名不能为空！${PLAIN}" && return 1
            d_args=""
            for d in $domain_input; do d_args="$d_args -d $d"; done
            certbot certonly --nginx $d_args --non-interactive --agree-tos -m "$ADMIN_EMAIL"
            ;;
        2)
            read -p "请输入要追加的证书名（原主域名）: " base_cert
            [ -z "$base_cert" ] && echo -e "${RED}不能为空！${PLAIN}" && return 1
            # 读取现有域名
            existing=$(certbot certificates --cert-name "$base_cert" 2>/dev/null | grep "Domains:" | sed 's/.*Domains: //')
            echo -e "${YELLOW}当前域名: $existing${PLAIN}"
            echo -e "${YELLOW}请输入要追加的新域名（空格分隔）:${PLAIN}"
            read -p "> " new_domains
            [ -z "$new_domains" ] && echo -e "${RED}不能为空！${PLAIN}" && return 1
            # 合并所有域名
            all_args=""
            for d in $existing $new_domains; do all_args="$all_args -d $d"; done
            certbot certonly --nginx --expand $all_args --non-interactive --agree-tos -m "$ADMIN_EMAIL"
            ;;
        3)
            certbot renew
            ;;
        *)
            echo -e "${RED}无效选择${PLAIN}"
            return 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}证书操作成功！${PLAIN}"
    else
        echo -e "${RED}证书操作失败，请检查域名 DNS！${PLAIN}"
    fi
}

# ══════════════════════════════════════════════════════════════
#  3) 删除主机
# ══════════════════════════════════════════════════════════════

del_host() {
    echo -e "${BLUE}=== 删除主机 ===${PLAIN}"

    conf_list=$(ls $NGINX_CONF_DIR/*.conf 2>/dev/null | grep -v default)
    if [ -z "$conf_list" ]; then
        echo -e "${YELLOW}暂无绑定的主机。${PLAIN}"
        return 0
    fi

    echo -e "${BLUE}当前已绑定的主机：${PLAIN}"
    i=1
    for f in $conf_list; do
        domain=$(basename "$f" .conf)
        echo "  $i) $domain"
        i=$((i+1))
    done

    read -p "请输入序号或域名: " del_input
    [ -z "$del_input" ] && return 0

    if echo "$del_input" | grep -qE '^[0-9]+$'; then
        del_domain=$(ls $NGINX_CONF_DIR/*.conf 2>/dev/null | grep -v default | sed -n "${del_input}p" | xargs basename 2>/dev/null | sed 's/\.conf//')
    else
        del_domain="$del_input"
    fi

    [ -z "$del_domain" ] && echo -e "${RED}无效输入${PLAIN}" && return 1

    read -p "确认删除主机 $del_domain ? (y/n): " confirm
    [ "$confirm" != "y" ] && echo "已取消。" && return 0

    rm -f "$NGINX_CONF_DIR/$del_domain.conf"
    nginx -t && rc-service nginx reload
    echo -e "${GREEN}主机 $del_domain 已删除！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  4) 删除证书
# ══════════════════════════════════════════════════════════════

cert_delete() {
    echo -e "${BLUE}=== 删除证书 ===${PLAIN}"

    cert_list=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README)
    if [ -z "$cert_list" ]; then
        echo -e "${YELLOW}暂无已申请的证书。${PLAIN}"
        return 0
    fi

    echo -e "${BLUE}已申请的证书：${PLAIN}"
    echo "$cert_list" | nl -w2 -s') '

    read -p "请输入序号或域名: " del_input
    [ -z "$del_input" ] && return 0

    if echo "$del_input" | grep -qE '^[0-9]+$'; then
        del_cert=$(echo "$cert_list" | sed -n "${del_input}p")
    else
        del_cert="$del_input"
    fi

    [ -z "$del_cert" ] && echo -e "${RED}无效输入${PLAIN}" && return 1

    read -p "确认删除证书 $del_cert ? (y/n): " confirm
    [ "$confirm" != "y" ] && echo "已取消。" && return 0

    certbot delete --cert-name "$del_cert"
    echo -e "${GREEN}证书 $del_cert 已删除！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  5) 重启 Nginx
# ══════════════════════════════════════════════════════════════

restart_nginx() {
    echo -e "${BLUE}正在重启 Nginx...${PLAIN}"
    rc-service nginx restart
    [ $? -eq 0 ] && echo -e "${GREEN}Nginx 重启成功！${PLAIN}" || echo -e "${RED}Nginx 重启失败！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  6) 重启 V2Ray
# ══════════════════════════════════════════════════════════════

restart_v2ray() {
    if [ -f /etc/init.d/v2ray ]; then
        echo -e "${BLUE}正在重启 V2Ray...${PLAIN}"
        rc-service v2ray restart
        [ $? -eq 0 ] && echo -e "${GREEN}V2Ray 重启成功！${PLAIN}" || echo -e "${RED}V2Ray 重启失败！${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 V2Ray，跳过。${PLAIN}"
    fi
}

# ══════════════════════════════════════════════════════════════
#  7) 删除 V2Ray
# ══════════════════════════════════════════════════════════════

remove_v2ray() {
    if [ -f /etc/init.d/v2ray ]; then
        read -p "确认删除 V2Ray? (y/n): " confirm
        [ "$confirm" != "y" ] && echo "已取消。" && return 0
        rc-service v2ray stop >/dev/null 2>&1
        rc-update del v2ray default >/dev/null 2>&1
        apk del v2ray >/dev/null 2>&1
        rm -rf /etc/v2ray
        echo -e "${GREEN}V2Ray 已删除！${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 V2Ray 安装。${PLAIN}"
    fi
}

# ══════════════════════════════════════════════════════════════
#  8) 安装 Nginx + MariaDB + PHP8.2 + V2Ray(可选)
# ══════════════════════════════════════════════════════════════

install_main() {
    echo -e "${BLUE}=== 开始安装环境 ===${PLAIN}"

    apk update && apk upgrade
    apk add --no-cache curl wget unzip ca-certificates tzdata

    # 时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    echo -e "${GREEN}时区已设置为上海${PLAIN}"

    # 管理邮箱
    while true; do
        read -p "请输入管理邮箱（用于申请 SSL 证书）: " ADMIN_EMAIL
        [ -n "$ADMIN_EMAIL" ] && break
        echo -e "${RED}邮箱不能为空！${PLAIN}"
    done
    echo "$ADMIN_EMAIL" > /etc/npm_admin_email

    # Nginx
    echo -e "${GREEN}正在安装 Nginx...${PLAIN}"
    apk add --no-cache nginx
    # 全局上传限制 64M（删除旧值再写入避免重复）
    sed -i '/client_max_body_size/d' /etc/nginx/nginx.conf
    sed -i '/http {/a\    client_max_body_size 64M;' /etc/nginx/nginx.conf
    rc-update add nginx default
    rc-service nginx start

    # MariaDB
    echo -e "${GREEN}正在安装 MariaDB...${PLAIN}"
    apk add --no-cache mariadb mariadb-client
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1
    rc-update add mariadb default
    rc-service mariadb start

    # 设置 root 密码及安全初始化
    while true; do
        read -p "请输入 MariaDB root 密码: " db_pass
        [ -n "$db_pass" ] && break
        echo -e "${RED}密码不能为空！${PLAIN}"
    done
    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_pass';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    echo -e "${GREEN}MariaDB 安全初始化完成！root 密码已设置。${PLAIN}"

    # PHP 8.2
    echo -e "${GREEN}正在安装 PHP 8.2...${PLAIN}"
    apk add --no-cache php82 php82-fpm php82-pdo php82-pdo_mysql php82-mysqlnd \
        php82-json php82-mbstring php82-xml php82-zip php82-curl php82-gd \
        php82-opcache php82-session php82-openssl php82-iconv php82-exif \
        php82-phar php82-intl php82-ctype php82-mysqli php82-fileinfo \
        php82-tokenizer php82-dom php82-xmlwriter php82-simplexml

    sed -i 's/user = nobody/user = nginx/' /etc/php82/php-fpm.d/www.conf
    sed -i 's/group = nobody/group = nginx/' /etc/php82/php-fpm.d/www.conf

    # PHP 内存/上传优化（适合 256-512M 内存）
	sed -i 's/^;date.timezone.*/date.timezone = Asia\/Shanghai/' /etc/php82/php.ini
    sed -i 's/^upload_max_filesize.*/upload_max_filesize = 64M/' /etc/php82/php.ini
    sed -i 's/^post_max_size.*/post_max_size = 64M/' /etc/php82/php.ini
    sed -i 's/^memory_limit.*/memory_limit = 128M/' /etc/php82/php.ini
    sed -i 's/^max_execution_time.*/max_execution_time = 120/' /etc/php82/php.ini

    # PHP-FPM 进程优化（256-512M 内存）
    sed -i 's/^pm =.*/pm = dynamic/' /etc/php82/php-fpm.d/www.conf
    sed -i 's/^pm.max_children.*/pm.max_children = 10/' /etc/php82/php-fpm.d/www.conf
    sed -i 's/^pm.start_servers.*/pm.start_servers = 2/' /etc/php82/php-fpm.d/www.conf
    sed -i 's/^pm.min_spare_servers.*/pm.min_spare_servers = 1/' /etc/php82/php-fpm.d/www.conf
    sed -i 's/^pm.max_spare_servers.*/pm.max_spare_servers = 4/' /etc/php82/php-fpm.d/www.conf

    rc-update add php-fpm82 default
    rc-service php-fpm82 start

    # Certbot
    echo -e "${GREEN}正在安装 Certbot...${PLAIN}"
    apk add --no-cache certbot certbot-nginx
    echo "0 0 * * * certbot renew --quiet" >> /etc/crontabs/root

    # phpMyAdmin
    echo -e "${GREEN}正在安装 phpMyAdmin...${PLAIN}"
    apk add --no-cache phpmyadmin
    mkdir -p /home/www
    chmod 777 /home/www
    PMA_SRC=$(find /usr/share/webapps /usr/share/phpmyadmin 2>/dev/null -maxdepth 1 -name "phpmyadmin" -type d | head -1)
    if [ -n "$PMA_SRC" ]; then
        cp -r "$PMA_SRC" /home/www/phpmyadmin
        chmod -R 777 /home/www/phpmyadmin
        echo -e "${GREEN}phpMyAdmin 已复制到 /home/www/phpmyadmin${PLAIN}"
    else
        echo -e "${YELLOW}phpMyAdmin 源目录未找到，请手动复制${PLAIN}"
    fi

    # /home 权限
    chmod 777 /home

    # V2Ray（可选）
    read -p "是否安装 V2Ray? (y/n): " install_v2ray
    if [ "$install_v2ray" = "y" ]; then
        apk add --no-cache v2ray

        while true; do
            read -p "请输入 V2Ray 专用域名: " v2_domain
            [ -n "$v2_domain" ] && break
            echo -e "${RED}域名不能为空！${PLAIN}"
        done

        read -p "请输入 WS 路径（默认 /v2ray）: " v2_path
        v2_path=${v2_path:-/v2ray}
        case $v2_path in /*) ;; *) v2_path="/$v2_path" ;; esac

        v2_uuid=$(cat /proc/sys/kernel/random/uuid)

        cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 10086,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$v2_uuid", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "$v2_path"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF

        echo -e "${GREEN}正在申请 V2Ray 域名证书...${PLAIN}"
        certbot certonly --nginx -d "$v2_domain" --non-interactive --agree-tos -m "$ADMIN_EMAIL"
        create_nginx_conf "$v2_domain" "" "v2ray" "$v2_path"

        rc-update add v2ray default
        rc-service v2ray start
        nginx -t && rc-service nginx reload

        echo ""
        echo -e "${GREEN}============================================${PLAIN}"
        echo -e "${BLUE}  V2Ray 客户端配置参数：${PLAIN}"
        echo -e "  协议:  ${RED}VLESS${PLAIN}"
        echo -e "  地址:  ${RED}$v2_domain${PLAIN}"
        echo -e "  端口:  ${RED}443${PLAIN}"
        echo -e "  UUID:  ${RED}$v2_uuid${PLAIN}"
        echo -e "  传输:  ${RED}WebSocket${PLAIN}"
        echo -e "  路径:  ${RED}$v2_path${PLAIN}"
        echo -e "  TLS:   ${RED}开启${PLAIN}"
        echo -e "${GREEN}============================================${PLAIN}"
    fi

    # 注册全局命令
    SCRIPT_PATH="$(readlink -f "$0")"
    if [ "$SCRIPT_PATH" != "/usr/local/bin/npm" ]; then
        cp "$SCRIPT_PATH" /usr/local/bin/npm
        chmod +x /usr/local/bin/npm
        echo -e "${GREEN}已注册全局命令，输入 npm 进入管理面板。${PLAIN}"
    fi

    echo -e "${GREEN}安装完成！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  9) 删除 Nginx + MariaDB + PHP8.2
# ══════════════════════════════════════════════════════════════

remove_all() {
    read -p "确认删除 Nginx+MariaDB+PHP8.2？此操作不可恢复！(y/n): " confirm
    [ "$confirm" != "y" ] && echo "已取消。" && return 0

    rc-service nginx stop >/dev/null 2>&1
    rc-service mariadb stop >/dev/null 2>&1
    rc-service php-fpm82 stop >/dev/null 2>&1
    rc-update del nginx default >/dev/null 2>&1
    rc-update del mariadb default >/dev/null 2>&1
    rc-update del php-fpm82 default >/dev/null 2>&1

    apk del --no-cache nginx mariadb mariadb-client \
        php82 php82-fpm php82-pdo php82-pdo_mysql php82-mysqlnd \
        php82-json php82-mbstring php82-xml php82-zip php82-curl php82-gd \
        php82-opcache php82-session php82-openssl php82-iconv php82-exif \
        php82-phar php82-intl php82-ctype php82-mysqli php82-fileinfo \
        php82-tokenizer php82-dom php82-xmlwriter php82-simplexml \
        certbot certbot-nginx phpmyadmin >/dev/null 2>&1

    rm -rf /etc/nginx /etc/php82 /var/lib/mysql /etc/letsencrypt
    echo -e "${GREEN}Nginx + MariaDB + PHP8.2 已删除！${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════════

main_menu() {
    load_email
    clear
    echo -e "${BLUE}========================================${PLAIN}"
    echo -e "${BLUE}           NPM 管理面板                 ${PLAIN}"
    echo -e "${BLUE}========================================${PLAIN}"
    echo -e "${GREEN}1) 添加主机${PLAIN}"
    echo -e "${GREEN}2) 重启 Nginx${PLAIN}"
    echo -e "${GREEN}3) 重启 V2Ray${PLAIN}"
    echo -e "${GREEN}4) 申请/续期证书（支持多域名）${PLAIN}"
    echo -e "${GREEN}5) 删除主机${PLAIN}"
    echo -e "${GREEN}6) 删除证书${PLAIN}"
    echo -e "${GREEN}7) 删除 V2Ray${PLAIN}"
    echo -e "${GREEN}8) 删除 Nginx+MariaDB+PHP8.2${PLAIN}"
    echo -e "${GREEN}9) 安装 Nginx+MariaDB+PHP8.2+V2Ray${PLAIN}"
    echo -e "${GREEN}0) 退出${PLAIN}"
    echo -e "${BLUE}========================================${PLAIN}"

    while true; do
        read -p "请输入操作序号 [0-9]: " menu_choice
        case "$menu_choice" in
            1) add_host;      break ;;
            2) restart_nginx; break ;;
            3) restart_v2ray; break ;;
            4) cert_apply;    break ;;
            5) del_host;      break ;;
            6) cert_delete;   break ;;
            7) remove_v2ray;  break ;;
            8) remove_all;    break ;;
            9) install_main;  break ;;
            0) echo -e "${BLUE}退出，再见！${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入 0-9！${PLAIN}" ;;
        esac
    done

    read -p "按回车键返回主菜单..."
    main_menu
}

main_menu
