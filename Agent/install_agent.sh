#!/bin/sh
# =====================================================
#   星尘探针 Agent 一键安装脚本 (V2 修复版)
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

    if [ -n "$NEED" ]; then
        warn "缺少:$NEED，正在安装..."
        case "$OS" in
            alpine) apk update -q && apk add -q curl || err "apk 失败" ;;
            debian) apt-get update -qq && apt-get install -y -qq curl gawk || err "apt 失败" ;;
            redhat) yum install -y -q curl gawk || err "yum 失败" ;;
            *) err "请手动安装: $NEED" ;;
        esac
    fi
    ok "核心依赖已就绪"
}

# ── 3. 交互输入 ──────────────────────────────────
collect_input() {
    title "配置节点信息"

    printf "  节点 ID（如 DE-1-200）: "
    read INPUT_ID
    [ -z "$INPUT_ID" ] && err "节点 ID 不能为空"

    printf "  上报间隔秒数（默认 2）: "
    read INPUT_INTERVAL
    [ -z "$INPUT_INTERVAL" ] && INPUT_INTERVAL=2

    printf "  服务器所在区域 (回车自动识别): "
    read INPUT_REGION
    if [ -z "$INPUT_REGION" ]; then
        info "正在通过 API 自动获取地理位置..."
        # 换用更稳定的 API
        INPUT_REGION=$(curl -sk --max-time 5 "http://ip-api.com/json/?lang=zh-CN" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        [ -z "$INPUT_REGION" ] && INPUT_REGION="德国" # 默认保底
        ok "自动识别为: $INPUT_REGION"
    fi

    SERVER_COUNT=1
    printf "\n  服务端 push.php 地址 (默认 https://tz.995566.xyz/push.php): "
    read S_URL
    [ -z "$S_URL" ] && S_URL="https://tz.995566.xyz/push.php"
    printf "  服务端 Token: "
    read S_TOKEN
    [ -z "$S_TOKEN" ] && err "Token 不能为空"
    
    SERVER_URL_1="$S_URL"
    SERVER_TOKEN_1="$S_TOKEN"
}

# ── 4. 生成 agent.sh (重点修复逻辑) ──────────────
generate_agent() {
    title "生成 Agent 脚本"

    # 使用临时文件逐行写入变量，彻底避免粘连
    cat > "$AGENT_PATH" << EOF
#!/bin/sh
# 星尘探针 Agent

# ═══ 配置区 ════════════════════════════════════
ID="${INPUT_ID}"
INTERVAL=${INPUT_INTERVAL}
REGION="${INPUT_REGION}"
SERVER_URL_1="${SERVER_URL_1}"
SERVER_TOKEN_1="${SERVER_TOKEN_1}"
SERVER_COUNT=1
# ════════════════════════════════════════════════

EOF

    # 写入主体逻辑 (注意对 \$ 的处理)
    cat >> "$AGENT_PATH" << 'AGENT_SCRIPT'
ARCH=$(uname -m)
if [ -f /etc/os-release ]; then
    # 修复版获取 OS：提取引号内的 PRETTY_NAME
    OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'=' -f2- | tr -d '"')
elif [ -f /etc/redhat-release ]; then
    OS=$(cat /etc/redhat-release)
else
    OS=$(uname -s)
fi

CPU_NAME=$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_NAME" ] && CPU_NAME=$(grep "Hardware" /proc/cpuinfo | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_NAME" ] && CPU_NAME="$ARCH"

get_cpu_stats() {
    grep '^cpu ' /proc/stat | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'
}
PREV_STATS=$(get_cpu_stats)

while true; do
    sleep $INTERVAL
    CURR_STATS=$(get_cpu_stats)
    set -- $PREV_STATS; p_u=$1; p_n=$2; p_s=$3; p_i=$4; p_io=$5; p_ir=$6; p_so=$7
    set -- $CURR_STATS; c_u=$1; c_n=$2; c_s=$3; c_i=$4; c_io=$5; c_ir=$6; c_so=$7
    du=$((c_u-p_u)); dn=$((c_n-p_n)); ds=$((c_s-p_s))
    di=$((c_i-p_i)); dio=$((c_io-p_io)); dir=$((c_ir-p_ir)); dso=$((c_so-p_so))
    total=$((du+dn+ds+di+dio+dir+dso))
    if [ "$total" -gt 0 ]; then
        used=$((total - di)); pc=$((used * 100 / total))
        [ "$pc" -gt 100 ] && pc=100
        if [ "$pc" -ge 100 ]; then CPU_USAGE="1.00"; elif [ "$pc" -lt 10 ]; then CPU_USAGE="0.0${pc}"; else CPU_USAGE="0.${pc}"; fi
    else
        CPU_USAGE="0.00"
    fi
    PREV_STATS=$CURR_STATS

    M_INFO=$(cat /proc/meminfo)
    M_TOTAL=$(echo "$M_INFO" | awk '/^MemTotal:/{print int($2/1024)}')
    M_AVAIL=$(echo "$M_INFO" | awk '/^MemAvailable:/{print int($2/1024)}')
    [ -z "$M_AVAIL" ] && M_AVAIL=0
    M_USED=$((M_TOTAL - M_AVAIL))
    [ "$M_USED" -lt 0 ] && M_USED=0

    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    D_INFO=$(df -Pm / | tail -n 1)
    D_TOTAL=$(echo "$D_INFO" | awk '{print $2}')
    D_USED=$(echo  "$D_INFO" | awk '{print $3}')

    NET_RAW=$(awk '/: /{
        gsub(/:/, " ")
        if ($1 != "lo") { rx += $2; tx += $10 }
    } END { print rx","tx }' /proc/net/dev)

    PROCESS_COUNT=$(ps -ef | wc -l)
    TCP_CONN=$(grep -v "local_address" /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l)
    UDP_CONN=$(grep -v "local_address" /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)

    _i=1
    while [ "$_i" -le "$SERVER_COUNT" ]; do
        eval "_URL=\$SERVER_URL_${_i}"; eval "_TOKEN=\$SERVER_TOKEN_${_i}"
        curl -sk --max-time 8 -X POST "$_URL" \
            -d "token=$_TOKEN" -d "id=$ID" -d "uptime=$UPTIME" \
            -d "load=$CPU_USAGE" -d "mem=$M_TOTAL,$M_USED" \
            -d "disk=$D_TOTAL,$D_USED" -d "net=$NET_RAW" \
            -d "process=$PROCESS_COUNT" -d "tcp=$TCP_CONN" -d "udp=$UDP_CONN" \
            -d "arch=$ARCH" -d "os=$OS" -d "region=$REGION" -d "cpu_name=$CPU_NAME" > /dev/null 2>&1
        _i=$((_i + 1))
    done
done
AGENT_SCRIPT

    chmod +x "$AGENT_PATH"
    ok "Agent 已生成并修复排版与抓取逻辑"
}

# ── 5. 自启逻辑保持一致 ──────────────────────────
setup_autostart() {
    title "设置开机自启"
    case "$OS" in
        alpine)
            mkdir -p /etc/local.d
            cat > /etc/local.d/probe-agent.start << 'EOF'
#!/bin/sh
nohup sh /root/agent.sh >> /var/log/agent.log 2>&1 &
EOF
            chmod +x /etc/local.d/probe-agent.start
            rc-update add local default >/dev/null 2>&1 ;;
        debian|redhat)
            cat > /etc/systemd/system/probe-agent.service << SVC
[Unit]
Description=Server Probe Agent
After=network.target
[Service]
Type=simple
ExecStart=/bin/sh $AGENT_PATH
Restart=always
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload && systemctl enable probe-agent >/dev/null 2>&1 ;;
    esac
    ok "自启配置完成"
}

start_agent() {
    title "启动 Agent"
    pkill -f "$AGENT_PATH" 2>/dev/null; sleep 1
    if [ "$OS" != "alpine" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart probe-agent 2>/dev/null && ok "启动成功" && return
    fi
    nohup sh $AGENT_PATH >> $LOG_PATH 2>&1 &
    ok "Agent 已后台运行"
}

main() {
    printf "\n${BOLD}${CYAN}  星尘探针 Agent 一键安装 (V2 修复版)${NC}\n\n"
    detect_os
    install_deps
    collect_input
    generate_agent
    setup_autostart
    start_agent
    title "安装完成"
    ok "日志查看: tail -f $LOG_PATH"
}

main
