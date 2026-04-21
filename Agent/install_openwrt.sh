#!/bin/sh
# =====================================================
#   星尘探针 Agent 一键安装脚本 (OpenWrt/ImmortalWrt 适配版)
#   适配固件: ImmortalWrt 23.05.x  架构: ARMv8 (v8l)
#   变更: opkg 包管理 / procd 自启动 / BusyBox 兼容
# =====================================================

AGENT_PATH="/root/agent.sh"
LOG_PATH="/var/log/agent.log"
INIT_SCRIPT="/etc/init.d/probe-agent"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[ERR ]${NC}  %s\n" "$1"; exit 1; }
title() { printf "\n${BOLD}━━━━  %s  ━━━━${NC}\n" "$1"; }

# OpenWrt 固定为 opkg，不做多系统检测
install_deps() {
    title "检查依赖"
    NEED=""
    command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
    # OpenWrt 自带 awk (BusyBox)，通常无需额外安装
    if [ -n "$NEED" ]; then
        info "正在通过 opkg 安装缺失依赖: $NEED"
        opkg update -q 2>/dev/null && opkg install $NEED 2>/dev/null || err "opkg 安装失败，请检查网络或手动安装: $NEED"
    fi
    ok "核心依赖已就绪"
}

collect_input() {
    title "配置节点信息"
    printf "  节点 ID: "
    read INPUT_ID
    [ -z "$INPUT_ID" ] && err "节点 ID 不能为空"

    printf "  上报间隔秒数 (默认 2): "
    read INPUT_INTERVAL
    [ -z "$INPUT_INTERVAL" ] && INPUT_INTERVAL=2

    printf "  服务器所在区域 (回车自动识别): "
    read INPUT_REGION
    if [ -z "$INPUT_REGION" ]; then
        INPUT_REGION=$(curl -sk --max-time 5 "http://ip-api.com/json/?lang=zh-CN" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        [ -z "$INPUT_REGION" ] && INPUT_REGION="未知地区"
        ok "自动识别为: $INPUT_REGION"
    fi

    printf "\n${YELLOW}  [提醒] 输入域名格式 (如: tz.995566.xyz)${NC}\n"
    printf "${YELLOW}  [多端] 若有多个服务端，请使用英文逗号分隔: , ${NC}\n"
    printf "  请输入服务端域名(默认: tz.995566.xyz): "
    read S_DOMAINS
    [ -z "$S_DOMAINS" ] && S_DOMAINS="tz.995566.xyz"

    printf "  服务端 Token (公用一个): "
    read S_TOKEN
    [ -z "$S_TOKEN" ] && err "Token 不能为空"
}

generate_agent() {
    title "生成 Agent 脚本"

    cat > "$AGENT_PATH" << EOF
#!/bin/sh
ID="${INPUT_ID}"
INTERVAL=${INPUT_INTERVAL}
REGION="${INPUT_REGION}"
SERVER_TOKEN="${S_TOKEN}"
EOF

    # 动态处理域名补齐逻辑
    _count=0
    OLD_IFS="$IFS"; IFS=","
    for dom in $S_DOMAINS; do
        _count=$((_count + 1))
        clean_dom=$(echo "$dom" | tr -d ' ')
        case "$clean_dom" in
            http*) final_url="$clean_dom" ;;
            *) final_url="https://$clean_dom" ;;
        esac
        final_url=$(echo "$final_url" | sed 's/\/*$//')"/push.php"
        echo "SERVER_URL_${_count}=\"$final_url\"" >> "$AGENT_PATH"
    done
    IFS="$OLD_IFS"
    echo "SERVER_COUNT=$_count" >> "$AGENT_PATH"

    cat >> "$AGENT_PATH" << 'AGENT_SCRIPT'
ARCH=$(uname -m)

# 获取系统信息：OpenWrt 用 /etc/openwrt_release；兜底用 uname
if [ -f /etc/openwrt_release ]; then
    OS=$(grep "^DISTRIB_DESCRIPTION=" /etc/openwrt_release | cut -d'=' -f2- | tr -d '"')
elif [ -f /etc/os-release ]; then
    OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'=' -f2- | tr -d '"')
else
    OS=$(uname -s)
fi
[ -z "$OS" ] && OS="OpenWrt"

# ARMv8 的 /proc/cpuinfo 通常无 "model name"，优先取 "Hardware" 字段
CPU_NAME=$(grep -m1 "^model name" /proc/cpuinfo | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_NAME" ] && CPU_NAME=$(grep -m1 "^Hardware" /proc/cpuinfo | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_NAME" ] && CPU_NAME="$ARCH"

get_cpu_stats() { grep '^cpu ' /proc/stat | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'; }
PREV_STATS=$(get_cpu_stats)

while true; do
    sleep $INTERVAL

    # CPU 使用率
    CURR_STATS=$(get_cpu_stats)
    set -- $PREV_STATS; p_u=$1; p_n=$2; p_s=$3; p_i=$4; p_io=$5; p_ir=$6; p_so=$7
    set -- $CURR_STATS; c_u=$1; c_n=$2; c_s=$3; c_i=$4; c_io=$5; c_ir=$6; c_so=$7
    total=$(( (c_u-p_u)+(c_n-p_n)+(c_s-p_s)+(c_i-p_i)+(c_io-p_io)+(c_ir-p_ir)+(c_so-p_so) ))
    if [ "$total" -gt 0 ]; then
        pc=$(( (total - (c_i - p_i)) * 100 / total ))
        [ "$pc" -gt 100 ] && pc=100
        if   [ "$pc" -ge 100 ]; then CPU_USAGE="1.00"
        elif [ "$pc" -lt 10  ]; then CPU_USAGE="0.0${pc}"
        else                         CPU_USAGE="0.${pc}"
        fi
    else
        CPU_USAGE="0.00"
    fi
    PREV_STATS=$CURR_STATS

    # 内存（单位 MB）
    M_TOTAL=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    M_AVAIL=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    M_USED=$((M_TOTAL - M_AVAIL))
    [ "$M_USED" -lt 0 ] && M_USED=0

    # 在线时间（秒）
    UPTIME=$(awk '{print int($1)}' /proc/uptime)

    # 磁盘：BusyBox df 支持 -m，但不一定支持 -P；用 -m 替代
    D_INFO=$(df -m / 2>/dev/null | tail -n 1)
    D_TOTAL=$(echo "$D_INFO" | awk '{print $2}')
    D_USED=$(echo  "$D_INFO" | awk '{print $3}')

    # 流量：上报网卡原始累计值（与 X86 Agent 一致，服务端计算增量）
    NET_REPORT=$(awk '/: /{gsub(/:/, " "); if ($1 != "lo") { rx += $2; tx += $10 }} END { print rx","tx }' /proc/net/dev)

    # 进程数（BusyBox ps 无 -e 参数，用 -w 或直接 ps）
    PROCESS_COUNT=$(ps 2>/dev/null | wc -l)

    # TCP/UDP 连接数（OpenWrt 通常有 /proc/net/tcp，IPv6 视内核支持而定）
    TCP_CONN=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -v "local_address" | wc -l)
    UDP_CONN=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | grep -v "local_address" | wc -l)

    # 多端并发上报
    _i=1
    while [ "$_i" -le "$SERVER_COUNT" ]; do
        eval "_URL=\$SERVER_URL_${_i}"
        curl -sk --max-time 8 -X POST "$_URL" \
            -d "token=$SERVER_TOKEN" -d "id=$ID"          \
            -d "uptime=$UPTIME"      -d "load=$CPU_USAGE"  \
            -d "mem=$M_TOTAL,$M_USED"                      \
            -d "disk=$D_TOTAL,$D_USED"                     \
            -d "net=$NET_REPORT"                           \
            -d "process=$PROCESS_COUNT"                    \
            -d "tcp=$TCP_CONN"       -d "udp=$UDP_CONN"    \
            -d "arch=$ARCH"          -d "os=$OS"           \
            -d "region=$REGION"      -d "cpu_name=$CPU_NAME" \
            > /dev/null 2>&1
        _i=$((_i + 1))
    done
done
AGENT_SCRIPT

    chmod +x "$AGENT_PATH"
    ok "Agent 脚本已生成: $AGENT_PATH"
}

# -------------------------------------------------------
# OpenWrt procd init 脚本（替代 systemd / local.d）
# -------------------------------------------------------
setup_autostart() {
    title "配置 procd 自启动"

    cat > "$INIT_SCRIPT" << 'INITEOF'
#!/bin/sh /etc/rc.common
# probe-agent procd init script
USE_PROCD=1
START=99
STOP=10

AGENT_PATH="/root/agent.sh"
LOG_PATH="/var/log/agent.log"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$AGENT_PATH"
    procd_set_param respawn 3600 5 0   # threshold(s) timeout(s) retry(0=无限)
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}

stop_service() {
    # procd 会自动 SIGTERM，此处可选额外清理
    :
}
INITEOF

    chmod +x "$INIT_SCRIPT"
    "$INIT_SCRIPT" enable 2>/dev/null && ok "procd 自启动已注册 (START=99)" || warn "自启动注册失败，请手动执行: $INIT_SCRIPT enable"
}

start_agent() {
    title "启动 Agent"
    # 停止旧实例（procd 管理的和后台裸跑的都清理）
    "$INIT_SCRIPT" stop 2>/dev/null
    pkill -f "$AGENT_PATH" 2>/dev/null
    sleep 1
    "$INIT_SCRIPT" start 2>/dev/null && ok "Agent 已通过 procd 启动" || {
        warn "procd 启动失败，回退到后台运行"
        nohup sh "$AGENT_PATH" >> "$LOG_PATH" 2>&1 &
        ok "Agent 已后台运行 (PID: $!)"
    }
}

main() {
    title "星尘探针 Agent 安装 (ImmortalWrt 23.05 / ARMv8 适配版)"
    install_deps
    collect_input
    generate_agent
    setup_autostart
    start_agent
    printf "\n"
    ok "安装完成！上报服务端数量: $SERVER_COUNT"
    info "查看日志: logread | grep probe  或  tail -f $LOG_PATH"
    info "手动控制: $INIT_SCRIPT start|stop|restart"
}

main
