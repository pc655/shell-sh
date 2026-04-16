#!/bin/sh
# =====================================================
#   星尘探针 Agent 一键安装脚本 (V4.2)
#   功能：支持参数安装、2秒高频上报、手动运行调试显示
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

detect_os() {
    if   [ -f /etc/alpine-release ]; then OS="alpine"
    elif [ -f /etc/debian_version ];  then OS="debian"
    elif [ -f /etc/redhat-release ];  then OS="redhat"
    else OS="unknown"
    fi
}

install_deps() {
    title "检查依赖"
    NEED=""
    command -v curl >/dev/null 2>&1 || NEED="$NEED curl"
    command -v awk  >/dev/null 2>&1 || NEED="$NEED awk"
    if [ -n "$NEED" ]; then
        case "$OS" in
            alpine) apk update -q && apk add -q curl || err "apk 失败" ;;
            debian) apt-get update -qq && apt-get install -y -qq curl gawk || err "apt 失败" ;;
            redhat) yum install -y -q curl gawk || err "yum 失败" ;;
            *) err "请手动安装: $NEED" ;;
        esac
    fi
    ok "核心依赖已就绪"
}

collect_input() {
    title "配置节点信息"
    
    # 解析命令行参数
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --id) INPUT_ID="$2"; shift 2 ;;
            --token) S_TOKEN="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # 节点 ID 检查
    if [ -z "$INPUT_ID" ]; then
        printf "  节点 ID: "
        read INPUT_ID
    fi
    [ -z "$INPUT_ID" ] && err "节点 ID 不能为空"

    # 区域识别
    INPUT_REGION=$(curl -sk --max-time 5 "http://ip-api.com/json/?lang=zh-CN" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
    [ -z "$INPUT_REGION" ] && INPUT_REGION="未知地区"
    ok "自动识别地区: $INPUT_REGION"

    # 默认域名配置（固化上报间隔为 2 秒）
    S_DOMAINS="tz.995566.xyz"
    S_INTERVALS="2"
    
    # Token 检查
    if [ -z "$S_TOKEN" ]; then
        printf "  服务端 Token: "
        read S_TOKEN
    fi
    [ -z "$S_TOKEN" ] && err "Token 不能为空"
}

generate_agent() {
    title "生成 Agent 脚本"

    cat > "$AGENT_PATH" << EOF
#!/bin/sh
ID="${INPUT_ID}"
REGION="${INPUT_REGION}"
SERVER_TOKEN="${S_TOKEN}"
EOF

    # 处理域名和 2 秒间隔
    _count=0
    for dom in $S_DOMAINS; do
        _count=$((_count + 1))
        case "$dom" in
            http*) final_url="$dom" ;;
            *) final_url="https://$dom" ;;
        esac
        final_url=\$(echo "\$final_url" | sed 's/\/*$//')
        case "\$dom" in
            *workers.dev*) final_url="\${final_url}/push" ;;
            *)             final_url="\${final_url}/push.php" ;;
        esac
        echo "SERVER_URL_${_count}=\"\$final_url\"" >> "$AGENT_PATH"
        echo "SERVER_INTERVAL_${_count}=2" >> "$AGENT_PATH"
    done
    echo "SERVER_COUNT=$_count" >> "$AGENT_PATH"

    # 写入 Agent 主逻辑
    cat >> "$AGENT_PATH" << 'AGENT_SCRIPT'
ARCH=$(uname -m)
[ -f /etc/os-release ] && OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'=' -f2- | tr -d '"') || OS=$(uname -s)
CPU_NAME=$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "$CPU_NAME" ] && CPU_NAME="$ARCH"

get_cpu_stats() { grep '^cpu ' /proc/stat | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'; }

_i=1
while [ "$_i" -le "$SERVER_COUNT" ]; do
    eval "LAST_PUSH_${_i}=0"
    _i=$((_i + 1))
done

PREV_STATS=$(get_cpu_stats)

# 检测是否在终端手动运行
[ -t 1 ] && DEBUG=1 || DEBUG=0

while true; do
    sleep 1
    NOW=$(awk '{print int($1)}' /proc/uptime)

    CURR_STATS=$(get_cpu_stats); set -- $PREV_STATS; p_u=$1; p_n=$2; p_s=$3; p_i=$4; p_io=$5; p_ir=$6; p_so=$7
    set -- $CURR_STATS; c_u=$1; c_n=$2; c_s=$3; c_i=$4; c_io=$5; c_ir=$6; c_so=$7
    total=$(( (c_u-p_u)+(c_n-p_n)+(c_s-p_s)+(c_i-p_i)+(c_io-p_io)+(c_ir-p_ir)+(c_so-p_so) ))
    if [ "$total" -gt 0 ]; then
        pc=$(((total - (c_i-p_i)) * 100 / total))
        [ "$pc" -gt 100 ] && pc=100
        if [ "$pc" -ge 100 ]; then CPU_USAGE="1.00"; elif [ "$pc" -lt 10 ]; then CPU_USAGE="0.0${pc}"; else CPU_USAGE="0.${pc}"; fi
    else CPU_USAGE="0.00"; fi
    PREV_STATS=$CURR_STATS

    M_TOTAL=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    M_AVAIL=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    M_USED=$((M_TOTAL - M_AVAIL)); [ "$M_USED" -lt 0 ] && M_USED=0
    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    D_INFO=$(df -Pm / | tail -n 1)
    D_TOTAL=$(echo "$D_INFO" | awk '{print $2}'); D_USED=$(echo "$D_INFO" | awk '{print $3}')
    NET_REPORT=$(awk '/: /{gsub(/:/, " "); if ($1 != "lo") { rx += $2; tx += $10 }} END { print rx","tx }' /proc/net/dev)
    PROCESS_COUNT=$(ps -ef | wc -l)
    TCP_CONN=$(grep -v "local_address" /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l)
    UDP_CONN=$(grep -v "local_address" /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)

    _i=1
    while [ "$_i" -le "$SERVER_COUNT" ]; do
        eval "_URL=\$SERVER_URL_${_i}"
        eval "_IV=\$SERVER_INTERVAL_${_i}"
        eval "_LAST=\$LAST_PUSH_${_i}"
        if [ "$(($NOW - $_LAST))" -ge "$_IV" ]; then
            POST_DATA="token=$SERVER_TOKEN&id=$ID&uptime=$UPTIME&load=$CPU_USAGE&mem=$M_TOTAL,$M_USED&disk=$D_TOTAL,$D_USED&net=$NET_REPORT&process=$PROCESS_COUNT&tcp=$TCP_CONN&udp=$UDP_CONN&arch=$ARCH&os=$OS&region=$REGION&cpu_name=$CPU_NAME"
            
            # 手动运行时打印上报内容
            if [ "$DEBUG" -eq 1 ]; then
                echo "[$(date '+%H:%M:%S')] 上报至 $_URL"
                echo "数据: $POST_DATA"
            fi

            curl -sk --max-time 5 -X POST "$_URL" -d "$POST_DATA" > /dev/null 2>&1
            eval "LAST_PUSH_${_i}=$NOW"
        fi
        _i=$((_i + 1))
    done
done
AGENT_SCRIPT

    chmod +x "$AGENT_PATH"
}

setup_autostart() {
    title "设置开机自启"
    if [ "$OS" = "alpine" ]; then
        mkdir -p /etc/local.d
        echo "nohup sh $AGENT_PATH > $LOG_PATH 2>&1 &" > /etc/local.d/probe-agent.start
        chmod +x /etc/local.d/probe-agent.start
        rc-update add local default >/dev/null 2>&1
    else
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
        systemctl daemon-reload && systemctl enable probe-agent >/dev/null 2>&1
    fi
}

start_agent() {
    title "启动 Agent"
    pkill -f "$AGENT_PATH" 2>/dev/null; sleep 1
    if [ "$OS" != "alpine" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart probe-agent 2>/dev/null && ok "后台服务启动成功" && return
    fi
    nohup sh $AGENT_PATH > $LOG_PATH 2>&1 &
    ok "Agent 已后台运行"
}

main() {
    detect_os
    install_deps
    collect_input "$@"
    generate_agent
    setup_autostart
    start_agent
    title "安装完成"
    echo "提示：如需查看实时上报内容，请执行: sh $AGENT_PATH"
}

main "$@"
