#!/bin/sh

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CADDYFILE=/etc/caddy/Caddyfile
PHP_SOCK="unix//run/php-fpm82.sock"
PHP_INI=/etc/php82/php.ini

# ══════════════════════════════════════════════════════════════
#  工具函数
# ══════════════════════════════════════════════════════════════

# 备份 Caddyfile
backup_caddyfile() {
    cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
}

# 检查域名是否已存在
domain_exists() {
    grep -q "^$1 {" "$CADDYFILE" 2>/dev/null
}

# 追加站点块到 Caddyfile
append_site_block() {
    local domain="$1"
    local site_dir="$2"
    local site_type="$3"   # php | php_rewrite | proxy
    local proxy_port="$4"

    case "$site_type" in
        php)
            cat >> "$CADDYFILE" <<EOF

$domain {
    root * $site_dir
    encode gzip
    php_fastcgi $PHP_SOCK
    file_server
}
EOF
            ;;
        php_rewrite)
            cat >> "$CADDYFILE" <<EOF

$domain {
    root * $site_dir
    encode gzip
    php_fastcgi $PHP_SOCK
    @notFound {
        not file {path} {path}/
    }
    rewrite @notFound /index.php?{query}
    file_server
}
EOF
            ;;
        proxy)
            cat >> "$CADDYFILE" <<EOF

$domain {
    reverse_proxy 127.0.0.1:$proxy_port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
EOF
            ;;
    esac
}

# 交互选择站点类型，返回到变量 SITE_TYPE
choose_site_type() {
    echo ""
    echo -e "${BLUE}请选择站点类型：${PLAIN}"
    echo "  1) PHP 无伪静态（普通 PHP 站）"
    echo "  2) PHP + 伪静态（Typecho / WordPress 等）"
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

# ══════════════════════════════════════════════════════════════
#  新增功能函数
# ══════════════════════════════════════════════════════════════

# 重启Caddy
restart_caddy() {
    echo -e "${BLUE}正在重启 Caddy 服务...${PLAIN}"
    rc-service caddy restart
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Caddy 重启成功！${PLAIN}"
    else
        echo -e "${RED}Caddy 重启失败！${PLAIN}"
    fi
}

# 重启V2Ray
restart_v2ray() {
    if [ -f /etc/init.d/v2ray ]; then
        echo -e "${BLUE}正在重启 V2Ray 服务...${PLAIN}"
        rc-service v2ray restart
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}V2Ray 重启成功！${PLAIN}"
        else
            echo -e "${RED}V2Ray 重启失败！${PLAIN}"
        fi
    else
        echo -e "${YELLOW}未检测到 V2Ray 安装，无需重启${PLAIN}"
    fi
}

# 删除V2Ray
remove_v2ray() {
    if [ -f /etc/init.d/v2ray ]; then
        echo -e "${BLUE}正在卸载 V2Ray...${PLAIN}"
        rc-service v2ray stop >/dev/null 2>&1
        rc-update del v2ray default >/dev/null 2>&1
        rm -rf /etc/v2ray /usr/local/v2ray /etc/init.d/v2ray
        # 清理Caddyfile中的V2Ray配置
        sed -i "/^[a-zA-Z0-9].*\{[^}]*v2ray[^}]*\}/d" "$CADDYFILE"
        rc-service caddy reload >/dev/null 2>&1
        echo -e "${GREEN}V2Ray 已成功卸载！${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 V2Ray 安装，无需删除${PLAIN}"
    fi
}

# 删除Caddy+PHP8.2+SQLite
remove_caddy_php() {
    echo -e "${BLUE}正在卸载 Caddy + PHP8.2 + SQLite...${PLAIN}"
    # 停止服务
    rc-service caddy stop >/dev/null 2>&1
    rc-service php-fpm82 stop >/dev/null 2>&1
    # 移除开机自启
    rc-update del caddy default >/dev/null 2>&1
    rc-update del php-fpm82 default >/dev/null 2>&1
    # 卸载软件包
    apk del --no-cache caddy php82 php82-fpm php82-pdo_sqlite php82-sqlite3 \
        php82-json php82-mbstring php82-xml php82-zip php82-curl \
        php82-gd php82-session php82-openssl php82-iconv php82-ctype \
        php82-fileinfo php82-tokenizer php82-dom php82-opcache >/dev/null 2>&1
    # 清理文件
    rm -rf /etc/caddy /etc/php82 /usr/bin/php /run/php-fpm82.sock
    echo -e "${GREEN}Caddy + PHP8.2 + SQLite 已成功卸载！${PLAIN}"
}

# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${BLUE}           CPS 管理面板                        ${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${GREEN}1) 安装Caddy+PHP8.2+SQLite+V2Ray${PLAIN}"
    echo -e "${GREEN}2) 添加主机${PLAIN}"
    echo -e "${GREEN}3) 删除主机${PLAIN}"
    echo -e "${GREEN}4) 重启Caddy${PLAIN}"
    echo -e "${GREEN}5) 重启V2Ray${PLAIN}"
    echo -e "${GREEN}6) 删除V2Ray${PLAIN}"
    echo -e "${GREEN}7) 删除Caddy+PHP8.2+SQLite${PLAIN}"
    echo -e "${GREEN}0) 退出${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"
    
    while true; do
        read -p "请输入操作序号 [0-7]: " menu_choice
        case "$menu_choice" in
            1) 
                # 执行原有初次安装逻辑（包含时区配置）
                install_main
                break
                ;;
            2) 
                add_host
                break
                ;;
            3) 
                del_host
                break
                ;;
            4) 
                restart_caddy
                break
                ;;
            5) 
                restart_v2ray
                break
                ;;
            6) 
                remove_v2ray
                break
                ;;
            7) 
                remove_caddy_php
                break
                ;;
            0) 
                echo -e "${BLUE}退出成功，再见！${PLAIN}"
                exit 0
                ;;
            *) 
                echo -e "${RED}无效输入，请输入 0-7 之间的数字！${PLAIN}"
                ;;
        esac
    done
    # 执行完操作后等待回车返回菜单
    read -p "按回车键返回主菜单..."
    main_menu
}

# 原有初次安装逻辑封装为函数
install_main() {
    echo -e "${BLUE}==============================================${PLAIN}"
    echo -e "${BLUE}    Alpine 极简部署脚本                        ${PLAIN}"
    echo -e "${BLUE}    PHP 8.2 + Caddy + V2Ray                   ${PLAIN}"
    echo -e "${BLUE}==============================================${PLAIN}"

    # ── 1. 基础环境（新增时区配置）────────────────────────────────────────────
    apk update && apk upgrade
    apk add --no-cache curl wget unzip ca-certificates bash nano
    # 安装tzdata并配置上海时区
    echo -e "${GREEN}正在配置系统时区为上海...${PLAIN}"
    apk add --no-cache tzdata
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone

    # ── 2. 交互询问 ───────────────────────────────────────────────
    # 管理邮箱（SSL 证书）
    while true; do
        read -p "请输入管理邮箱 (用于申请 SSL 证书): " admin_email
        [ -n "$admin_email" ] && break
        echo -e "${RED}邮箱不能为空！${PLAIN}"
    done

    # V2Ray
    read -p "是否安装 V2Ray? (y/n): " install_v2ray
    if [ "$install_v2ray" = "y" ]; then
        while true; do
            read -p "请输入 V2Ray 域名 (例: a.cctv.xyz): " v2_domain
            [ -n "$v2_domain" ] && break
            echo -e "${RED}域名不能为空！${PLAIN}"
        done
        read -p "请输入 V2Ray 路径 (直接回车默认 /v2ray): " v2_path
        v2_path=${v2_path:-/v2ray}
        case $v2_path in /*) ;; *) v2_path="/$v2_path" ;; esac
        v2_uuid=$(cat /proc/sys/kernel/random/uuid)
    fi

    # ── 3. PHP 8.2 ───────────────────────────────────────────────
    echo -e "${GREEN}正在安装 PHP 8.2 组件...${PLAIN}"
    apk add --no-cache php82 php82-fpm php82-pdo_sqlite php82-sqlite3 \
            php82-json php82-mbstring php82-xml php82-zip php82-curl \
            php82-gd php82-session php82-openssl php82-iconv php82-ctype \
            php82-fileinfo php82-tokenizer php82-dom php82-opcache

    [ ! -f /usr/bin/php ] && ln -s /usr/bin/php82 /usr/bin/php

    getent group www-data >/dev/null  || addgroup -g 82 www-data
    getent passwd www-data >/dev/null || adduser -D -H -u 82 -G www-data www-data

    # 修改 php.ini 设置时区 (只改不删原则)
    if [ -f "$PHP_INI" ]; then
        echo -e "${GREEN}正在配置 PHP 时区...${PLAIN}"
        if grep -q "^;*date.timezone =" "$PHP_INI"; then
            sed -i "s|^;*date.timezone =.*|date.timezone = Asia/Shanghai|" "$PHP_INI"
        else
            echo "date.timezone = Asia/Shanghai" >> "$PHP_INI"
        fi
    fi

    cat > /etc/php82/php-fpm.d/www.conf <<EOF
[www]
user = www-data
group = www-data
listen = /run/php-fpm82.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
pm.max_requests = 100
php_value[memory_limit] = 32M
EOF

    rc-update add php-fpm82 default
    rc-service php-fpm82 restart

    # ── 4. Caddy ─────────────────────────────────────────────────
    echo -e "${GREEN}正在配置 Caddy...${PLAIN}"
    apk add --no-cache caddy

    cat > "$CADDYFILE" <<EOF
{
    email $admin_email
}
EOF

    if [ "$install_v2ray" = "y" ]; then
        cat >> "$CADDYFILE" <<EOF

$v2_domain {
    handle $v2_path* {
        reverse_proxy 127.0.0.1:10086 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }
    handle {
        respond "Service Running" 200
    }
}
EOF
    fi

    rc-update add caddy default
    rc-service caddy restart

    # ── 5. V2Ray ─────────────────────────────────────────────────
    if [ "$install_v2ray" = "y" ]; then
        echo -e "${GREEN}正在下载并配置 V2Ray...${PLAIN}"
        mkdir -p /usr/local/v2ray /etc/v2ray
        wget -q https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip \
             -O /tmp/v2ray.zip
        unzip -q /tmp/v2ray.zip -d /usr/local/v2ray/
        chmod +x /usr/local/v2ray/v2ray

        cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 10086,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$v2_uuid",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$v2_path"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

        cat > /etc/init.d/v2ray << 'INITEOF'
#!/sbin/openrc-run
name="v2ray"
command="/usr/local/v2ray/v2ray"
command_args="run -config /etc/v2ray/config.json"
command_background=true
pidfile="/run/v2ray.pid"
depend() { need net; }
INITEOF
        chmod +x /etc/init.d/v2ray
        rc-update add v2ray default
        rc-service v2ray restart
    fi

    # ── 6. 询问是否立即绑定博客域名 ──────────────────────────────
    echo ""
    read -p "是否现在绑定一个博客/网站域名? (y/n): " bind_now
    if [ "$bind_now" = "y" ]; then
        while true; do
            read -p "请输入域名 (例: cctv.xyz): " blog_domain
            [ -n "$blog_domain" ] && break
            echo -e "${RED}域名不能为空！${PLAIN}"
        done

        choose_site_type

        if [ "$SITE_TYPE" = "proxy" ]; then
            while true; do
                read -p "请输入转发端口 (例: 3000): " proxy_port
                echo "$proxy_port" | grep -qE '^[0-9]+$' && break
                echo -e "${RED}端口必须为数字！${PLAIN}"
            done
            append_site_block "$blog_domain" "" "proxy" "$proxy_port"
        else
            read -p "请输入网站目录 (默认 /home/www/blog): " blog_dir
            blog_dir=${blog_dir:-/home/www/blog}
            mkdir -p "$blog_dir"
            chown -R www-data:www-data "$blog_dir"
            chmod -R 755 "$blog_dir"
            append_site_block "$blog_domain" "$blog_dir" "$SITE_TYPE" ""
        fi

        rc-service caddy reload
        echo -e "${GREEN}域名 $blog_domain 已绑定完成。${PLAIN}"
    fi

    # ── 注册全局 cps 命令 ─────────────────────────────────────────
    SCRIPT_PATH="$(readlink -f "$0")"
    if [ "$SCRIPT_PATH" != "/usr/local/bin/cps" ]; then
        cp "$SCRIPT_PATH" /usr/local/bin/cps
        chmod +x /usr/local/bin/cps
        echo -e "${GREEN}已注册全局命令，今后直接输入 cps 即可进入管理面板。${PLAIN}"
    fi

    # ── 最终输出 ──────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}  部署完成！${PLAIN}"

    if [ "$install_v2ray" = "y" ]; then
        echo -e ""
        echo -e "${BLUE}  V2Ray 客户端配置参数：${PLAIN}"
        echo -e "  协议:         ${RED}VLESS${PLAIN}"
        echo -e "  地址:         ${RED}$v2_domain${PLAIN}"
        echo -e "  端口:         ${RED}443${PLAIN}"
        echo -e "  UUID:         ${RED}$v2_uuid${PLAIN}"
        echo -e "  加密:         ${RED}none${PLAIN}"
        echo -e "  传输协议:     ${RED}ws${PLAIN}"
        echo -e "  路径:         ${RED}$v2_path${PLAIN}"
        echo -e "  TLS:          ${RED}tls${PLAIN}"
        echo -e "  跳过证书验证: ${RED}false${PLAIN}"
    fi

    echo -e "${GREEN}==============================================${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  添加主机
# ══════════════════════════════════════════════════════════════

add_host() {
    echo -e "${BLUE}=== 追加新域名 ===${PLAIN}"

    # 检查环境是否已安装
    if ! command -v caddy >/dev/null 2>&1 || [ ! -f "$CADDYFILE" ]; then
        echo -e "${RED}错误：未检测到 Caddy 环境，请先执行安装（选项 1）后再添加主机。${PLAIN}"
        return 1
    fi

    # 域名
    while true; do
        read -p "请输入域名 (例: cctv.xyz): " new_domain
        [ -n "$new_domain" ] && break
        echo -e "${RED}域名不能为空！${PLAIN}"
    done

    # 检查是否已存在
    if domain_exists "$new_domain"; then
        echo -e "${RED}域名 $new_domain 已存在于 Caddyfile，请先删除后再添加。${PLAIN}"
        return 1
    fi

    # 站点类型
    choose_site_type

    # 反向代理：只需要端口
    if [ "$SITE_TYPE" = "proxy" ]; then
        while true; do
            read -p "请输入转发端口 (例: 3000): " proxy_port
            echo "$proxy_port" | grep -qE '^[0-9]+$' && break
            echo -e "${RED}端口必须为数字！${PLAIN}"
        done
        backup_caddyfile
        append_site_block "$new_domain" "" "proxy" "$proxy_port"
    else
        # 需要网站目录
        while true; do
            read -p "请输入网站目录 (例: /home/www/site): " new_dir
            [ -n "$new_dir" ] && break
            echo -e "${RED}目录不能为空！${PLAIN}"
        done
        mkdir -p "$new_dir"
        chown -R www-data:www-data "$new_dir"
        chmod -R 755 "$new_dir"
        backup_caddyfile
        append_site_block "$new_domain" "$new_dir" "$SITE_TYPE" ""
    fi

    rc-service caddy reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}警告：Caddy reload 失败，域名配置已写入但服务未生效，请检查 Caddyfile 语法！${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}完成！$new_domain 已添加到 Caddyfile。${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  删除主机
# ══════════════════════════════════════════════════════════════

del_host() {
    echo -e "${BLUE}=== 删除域名 ===${PLAIN}"

    echo -e "${BLUE}当前已绑定的域名：${PLAIN}"
    grep -E '^[a-zA-Z0-9].*\{' "$CADDYFILE" | sed 's/ {//' | nl -w2 -s'. '
    echo ""

    # 域名（禁止空值）
    while true; do
        read -p "请输入要删除的域名 (例: cctv.xyz): " del_domain
        [ -n "$del_domain" ] && break
        echo -e "${RED}域名不能为空！${PLAIN}"
    done

    # 检查是否存在
    if ! domain_exists "$del_domain"; then
        echo -e "${RED}未找到域名 $del_domain，请检查拼写。${PLAIN}"
        return 1
    fi

    # 二次确认
    read -p "确认删除 $del_domain ? (y/n): " confirm
    [ "$confirm" != "y" ] && echo "已取消。" && return 0

    backup_caddyfile

    # awk 安全删除：精确匹配 "domain {" 整行，逐字符计数括号深度
    awk -v domain="$del_domain {" '
        /^[[:space:]]*$/ { blank = blank "\n"; next }
        $0 == domain { skip = 1; depth = 1; blank = ""; next }
        skip {
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") depth--
            }
            if (depth <= 0) { skip = 0; blank = "" }
            next
        }
        { printf "%s", blank; blank = ""; print }
    ' "$CADDYFILE" > /tmp/Caddyfile.tmp

    mv /tmp/Caddyfile.tmp "$CADDYFILE"
    rc-service caddy reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}警告：Caddy reload 失败，配置已修改但服务未生效，请检查 Caddyfile 语法！${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}完成！$del_domain 已删除。${PLAIN}"
}

# ══════════════════════════════════════════════════════════════
#  脚本入口
# ══════════════════════════════════════════════════════════════

main_menu
