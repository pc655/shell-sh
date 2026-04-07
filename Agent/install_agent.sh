#!/bin/sh
# =====================================================
#  星尘探针 Agent 一键安装脚本
#  支持多服务端推送 | Alpine / Debian / Ubuntu
# =====================================================

AGENT_PATH="/root/agent.sh"
LOG_PATH="/var/log/agent.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[ERR ]${NC}  %s\n" "$1"; exit 1; }
title() { printf "\n${BOLD}━━━━  %s  ━━━━${NC}\n" "$1"; }

# ── 1. 检测系统 ──────────────────────────────────
detect_os() {
    if   [ -f /etc/alpine-release ]; then OS="alpine"
    elif [ -f /etc/debian_version ];  then OS="debian"
    elif [ -f /etc/redhat-release ];  then OS="redhat"
    else OS="unknown"
    fi
}

# ── 2. 安装依赖 ──────────────────────────────────
install_deps() {
    title "检查依赖"
    NEED=""
    command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
    command -v awk  >/dev/null 2>&1 || NEED="$NEED awk"

    if [ -z "$NEED" ]; then
        ok "curl / awk 已就绪"
        return
    fi

    warn "缺少:$NEED，正在安装..."
    case "$OS" in
        alpine)
            apk update -q && apk add -q curl || err "apk 安装失败"
            ok "依赖安装完毕（busybox awk 可用）"
            ;;
        debian)
            apt-get update -qq && apt-get install -y -qq curl gawk \
                || err "apt 安装失败，请手动: apt-get install curl gawk"
            ok "依赖安装完毕"
            ;;
        redhat)
            yum install -y -q curl gawk || err "yum 安装失败"
            ok "依赖安装完毕"
            ;;
        *)
            err "未识别系统，请手动安装: $NEED"
            ;;
    esac
}

# ── 3. 交互输入 ──────────────────────────────────
collect_input() {
    title "配置节点信息"

    printf "  节点 ID（面板显示名，如 HK-01）: "
    read INPUT_ID
    [ -z "$INPUT_ID" ] && err "节点 ID 不能为空"

    printf "  上报间隔秒数（默认 2，回车跳过）: "
    read INPUT_INTERVAL
    [ -z "$INPUT_INTERVAL" ] && INPUT_INTERVAL=2

    title "配置服务端（支持多个，逐个填写）"
    SERVER_COUNT=0

    # 第一个服务端：有默认值
    DEFAULT_URL="https://tz.995566.xyz/push.php"
    printf "\n  第 1 个服务端 push.php 地址（默认 %s）: " "$DEFAULT_URL"
    read S_URL
    [ -z "$S_URL" ] && S_URL="$DEFAULT_URL"
    printf "  第 1 个服务端 Token: "
    read S_TOKEN
    [ -z "$S_TOKEN" ] && err "Token 不能为空"
    SERVER_COUNT=1
    eval "SERVER_URL_1=\"${S_URL}\""
    eval "SERVER_TOKEN_1=\"${S_TOKEN}\""
    ok "已添加服务端 1: ${S_URL}"

    while true; do
        NEXT=$((SERVER_COUNT + 1))
        printf "\n  第 %d 个服务端 push.php 完整地址（留空结束）: " "$NEXT"
        read S_URL
        [ -z "$S_URL" ] && break

        printf "  第 %d 个服务端 Token: " "$NEXT"
        read S_TOKEN
        [ -z "$S_TOKEN" ] && err "Token 不能为空"

        SERVER_COUNT=$NEXT
        eval "SERVER_URL_${SERVER_COUNT}=\"${S_URL}\""
        eval "SERVER_TOKEN_${SERVER_COUNT}=\"${S_TOKEN}\""
        ok "已添加服务端 ${SERVER_COUNT}: ${S_URL}"
    done
}

# ── 4. 生成 agent.sh ─────────────────────────────
generate_agent() {
    title "生成 Agent 脚本"

    # 拼接服务端变量块
    SRV_VARS=""
    i=1
    while [ "$i" -le "$SERVER_COUNT" ]; do
        eval "_U=\$SERVER_URL_${i}"
        eval "_T=\$SERVER_TOKEN_${i}"
        SRV_VARS="${SRV_VARS}SERVER_URL_${i}=\"${_U}\"
SERVER_TOKEN_${i}=\"${_T}\"
"
        i=$((i+1))
    done

    cat > "$AGENT_PATH" << AGENT_SCRIPT
#!/bin/sh
# 星尘探针 Agent — 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')

# ═══ 配置区（如需修改请编辑此处）════════════════
ID="${INPUT_ID}"
INTERVAL=${INPUT_INTERVAL}

# 服务端列表
${SRV_VARS}SERVER_COUNT=${SERVER_COUNT}
# ════════════════════════════════════════════════

get_cpu_stats() {
    grep '^cpu ' /proc/stat | awk '{print \$2" "\$3" "\$4" "\$5" "\$6" "\$7" "\$8}'
}

PREV_STATS=\$(get_cpu_stats)

while true; do
    sleep \$INTERVAL

    # CPU
    CURR_STATS=\$(get_cpu_stats)
    set -- \$PREV_STATS
    p_u=\$1; p_n=\$2; p_s=\$3; p_i=\$4; p_io=\$5; p_ir=\$6; p_so=\$7
    set -- \$CURR_STATS
    c_u=\$1; c_n=\$2; c_s=\$3; c_i=\$4; c_io=\$5; c_ir=\$6; c_so=\$7
    du=\$((c_u-p_u)); dn=\$((c_n-p_n)); ds=\$((c_s-p_s))
    di=\$((c_i-p_i)); dio=\$((c_io-p_io)); dir=\$((c_ir-p_ir)); dso=\$((c_so-p_so))
    total=\$((du+dn+ds+di+dio+dir+dso))
    if [ "\$total" -gt 0 ]; then
        used=\$((total - di))
        pc=\$((used * 100 / total))
        [ "\$pc" -gt 100 ] && pc=100
        if   [ "\$pc" -ge 100 ]; then CPU_USAGE="1.00"
        elif [ "\$pc" -lt  10 ]; then CPU_USAGE="0.0\${pc}"
        else                          CPU_USAGE="0.\${pc}"
        fi
    else
        CPU_USAGE="0.00"
    fi
    PREV_STATS=\$CURR_STATS

    # 内存
    M_INFO=\$(cat /proc/meminfo)
    M_TOTAL=\$(echo "\$M_INFO" | awk '/^MemTotal:/{print int(\$2/1024)}')
    M_AVAIL=\$(echo "\$M_INFO" | awk '/^MemAvailable:/{print int(\$2/1024)}')
    [ -z "\$M_AVAIL" ] && M_AVAIL=0
    M_USED=\$((M_TOTAL - M_AVAIL))
    [ "\$M_USED" -lt 0 ] && M_USED=0

    # 在线时长
    UPTIME=\$(awk '{print int(\$1)}' /proc/uptime)

    # 磁盘
    D_INFO=\$(df -Pm / | tail -n 1)
    D_TOTAL=\$(echo "\$D_INFO" | awk '{print \$2}')
    D_USED=\$(echo  "\$D_INFO" | awk '{print \$3}')

    # 网络（汇总所有非 lo 网卡）
    NET_RAW=\$(awk '/: /{
        gsub(/:/, " ")
        if (\$1 != "lo") { rx += \$2; tx += \$10 }
    } END { print rx","tx }' /proc/net/dev)

    # 向所有服务端推送
    _i=1
    while [ "\$_i" -le "\$SERVER_COUNT" ]; do
        eval "_URL=\\\$SERVER_URL_\${_i}"
        eval "_TOKEN=\\\$SERVER_TOKEN_\${_i}"
        curl -sk --max-time 8 -X POST "\$_URL" \
            -d "token=\$_TOKEN" \
            -d "id=\$ID" \
            -d "uptime=\$UPTIME" \
            -d "load=\$CPU_USAGE" \
            -d "mem=\$M_TOTAL,\$M_USED" \
            -d "disk=\$D_TOTAL,\$D_USED" \
            -d "net=\$NET_RAW" > /dev/null 2>&1
        _i=\$((_i + 1))
    done

    echo "\$(date '+%H:%M:%S') CPU:\${CPU_USAGE} MEM:\${M_USED}/\${M_TOTAL}MB UP:\${UPTIME}s"
done
AGENT_SCRIPT

    sed -i 's/\r$//' "$AGENT_PATH"
    chmod +x "$AGENT_PATH"
    ok "Agent 已生成: $AGENT_PATH"
}

# ── 5. 开机自启 ──────────────────────────────────
setup_autostart() {
    title "设置开机自启"

    case "$OS" in
        alpine)
            # 用 OpenRC local.d 脚本，比 crontab @reboot 可靠
            mkdir -p /etc/local.d
            cat > /etc/local.d/probe-agent.start << 'LOCALEOF'
#!/bin/sh
nohup sh /root/agent.sh > /dev/null 2>&1 &
LOCALEOF
            chmod +x /etc/local.d/probe-agent.start
            # 确保 local 服务已启用
            rc-update add local default >/dev/null 2>&1
            ok "已注册 OpenRC local.d 开机自启"
            ;;
        debian|redhat)
            cat > /etc/systemd/system/probe-agent.service << SVC
[Unit]
Description=Server Probe Agent
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh $AGENT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload
            systemctl enable probe-agent >/dev/null 2>&1
            ok "已注册 systemd 服务（probe-agent）"
            ;;
        *)
            warn "未知系统，请手动配置开机自启"
            ;;
    esac
}

# ── 6. 启动 ─────────────────────────────────────
start_agent() {
    title "启动 Agent"
    pkill -f "/root/agent.sh" 2>/dev/null; sleep 1

    case "$OS" in
        debian|redhat)
            systemctl restart probe-agent 2>/dev/null && ok "systemd 服务已启动" && return
            ;;
    esac

    nohup sh /root/agent.sh > /dev/null 2>&1 &
    sleep 2
    if pgrep -f "/root/agent.sh" >/dev/null 2>&1; then
        ok "Agent 已启动（PID: $(pgrep -f /root/agent.sh)）"
    else
        ok "Agent 安装完成，请手动启动："
        printf "  nohup sh /root/agent.sh > /dev/null 2>&1 &\n"
    fi
}

# ── 主流程 ───────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}  星尘探针 Agent 一键安装${NC}\n"
    printf "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

    detect_os
    info "系统: $OS"

    install_deps
    collect_input
    generate_agent
    setup_autostart
    start_agent

    title "完成"
    ok "节点 ID    : ${INPUT_ID}"
    ok "服务端数量 : ${SERVER_COUNT} 个"
    ok "上报间隔   : ${INPUT_INTERVAL} 秒"
    ok "日志路径   : ${LOG_PATH}"
    printf "\n  常用命令:\n"
    printf "  查看日志  tail -f %s\n" "$LOG_PATH"
    printf "  停  止    pkill -f agent.sh\n"
    printf "  重  启    pkill -f agent.sh; nohup sh %s >> %s 2>&1 &\n\n" "$AGENT_PATH" "$LOG_PATH"
}

main
