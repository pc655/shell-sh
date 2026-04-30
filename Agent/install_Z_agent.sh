#!/bin/sh
# =============================================
# install_agent.sh - 监控 Agent 安装脚本
# 用法：curl -L URL | sh -s -- --id ID --token TOKEN --api URL
# =============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }
title() { printf "\n${BOLD}${CYAN}==> %s${NC}\n" "$*"; }

AGENT_FILE="/usr/local/bin/agent.sh"
PID_FILE="/var/run/agent_monitor.pid"
LOG_FILE="/var/log/agent_monitor.log"

# ---------- 命令行参数解析 ----------
NODE_ID=""
S_TOKEN=""
S_API=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --id)    NODE_ID="$2";  shift 2 ;;
        --token) S_TOKEN="$2";  shift 2 ;;
        --api)   S_API="$2";    shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$NODE_ID" ] && error "--id 不能为空"
[ -z "$S_TOKEN" ] && error "--token 不能为空"
[ -z "$S_API"   ] && error "--api 不能为空"

# 拼接推送 URL
_base=$(echo "$S_API" | sed 's|/*$||')
case "$_base" in
    *workers.dev*) PUSH_URL="${_base}/push" ;;
    *)             PUSH_URL="${_base}/push.php" ;;
esac

# SERVERS 格式：URL|TOKEN|INTERVAL
SERVERS_CONF="${PUSH_URL}|${S_TOKEN}|2"

# =============================================
# 1. 检测系统 + 自动安装依赖
# =============================================
detect_os() {
    title "检测系统环境"
    if [ -f /etc/alpine-release ]; then
        SYS_TYPE="alpine"; ok "Alpine Linux $(cat /etc/alpine-release)"
    elif [ -f /etc/debian_version ]; then
        SYS_TYPE="debian"; ok "Debian/Ubuntu $(cat /etc/debian_version)"
    else
        SYS_TYPE="other"; warn "未识别系统，将按通用 sh 处理"
    fi

    NEED=""
    # 检查命令是否存在
    for cmd in curl awk grep ps df; do
        command -v "$cmd" >/dev/null 2>&1 || NEED="$NEED $cmd"
    done

    if [ -n "$NEED" ] || [ "$SYS_TYPE" = "alpine" ]; then
        info "正在配置系统依赖..."
        case "$SYS_TYPE" in
            alpine)
                # 关键点：将 awk 改为 gawk，并添加 grep (Alpine 默认也是 busybox 版)
                apk update -q && apk add -q curl procps coreutils gawk grep || error "apk 安装失败" 
                ;;
            debian)
                apt-get update -qq && apt-get install -y -qq curl gawk procps || error "apt 安装失败" 
                ;;
            *)
                [ -n "$NEED" ] && error "请手动安装：$NEED" 
                ;;
        esac
    fi
    ok "依赖检查通过"
}

# =============================================
# 2. 自动查地区
# =============================================
detect_region() {
    title "查询节点地区"
    NODE_REGION=$(curl -sk --max-time 5 "http://ip-api.com/json/?lang=zh-CN" \
        | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
    [ -z "$NODE_REGION" ] && NODE_REGION="未知地区"
    ok "自动识别地区：$NODE_REGION"
}

# =============================================
# 3. 检测主网卡
# =============================================
detect_nic() {
    title "检测网卡"

    CANDIDATES=$(awk 'NR>2 {
        gsub(/:/, "", $1)
        if ($1 !~ /^(lo|docker|veth|br-|virbr|tun|tap|dummy|bond|sit|flannel|cni|kube)/)
            print $1
    }' /proc/net/dev)

    NIC_COUNT=$(echo "$CANDIDATES" | grep -c .)
    [ "$NIC_COUNT" -eq 0 ] && error "未检测到有效网卡"

    if [ "$NIC_COUNT" -eq 1 ]; then
        FINAL_NIC=$(echo "$CANDIDATES" | head -n 1)
        ok "自动选定网卡：$FINAL_NIC"
        return
    fi

    info "检测到多块网卡，按累计流量排序："
    printf "\n"
    for _nic in $CANDIDATES; do
        _rx=$(awk -v n="${_nic}:" '$0 ~ n {gsub(/:/, " "); print $2; exit}' /proc/net/dev)
        _tx=$(awk -v n="${_nic}:" '$0 ~ n {gsub(/:/, " "); print $10; exit}' /proc/net/dev)
        printf "  %-12s  RX:%-14d TX:%-14d\n" "$_nic" "${_rx:-0}" "${_tx:-0}"
    done
    printf "\n"

    FINAL_NIC=$(awk 'NR>2 {
        gsub(/:/, " ")
        if ($1 !~ /^(lo|docker|veth|br-|virbr|tun|tap|dummy|bond|sit|flannel|cni|kube)/) {
            total = $2 + $10
            if (total > max) { max = total; nic = $1 }
        }
    } END { print nic }' /proc/net/dev)

    ok "自动选定网卡（流量最大）：$FINAL_NIC"
}

# =============================================
# 4. 生成 agent.sh
# =============================================
generate_agent() {
    title "生成 agent.sh"
    mkdir -p "$(dirname $AGENT_FILE)"

    cat > "$AGENT_FILE" << AGENT_EOF
#!/bin/sh
# 由 install_agent.sh 自动生成 $(date '+%Y-%m-%d %H:%M:%S')
ID="${NODE_ID}"
REGION="${NODE_REGION}"
NIC="${FINAL_NIC}"
MAX_RETRY=3
SERVERS="${SERVERS_CONF}"

ARCH=\$(uname -m)
[ -f /etc/os-release ] && OS=\$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'=' -f2- | tr -d '"') || OS=\$(uname -s)
CPU_NAME=\$(grep "model name" /proc/cpuinfo | head -n 1 | cut -d':' -f2 | sed 's/^[ \t]*//')
[ -z "\$CPU_NAME" ] && CPU_NAME="\$ARCH"

get_cpu_stats() {
    _retry=0
    while [ \$_retry -lt \$MAX_RETRY ]; do
        _stats=\$(grep '^cpu ' /proc/stat | awk '{print \$2" "\$3" "\$4" "\$5" "\$6" "\$7" "\$8}')
        [ -n "\$_stats" ] && echo "\$_stats" && return 0
        _retry=\$((\$_retry + 1))
        sleep 1
    done
    echo "0 0 0 0 0 0 0"
}

get_net_stats() {
    _retry=0
    while [ \$_retry -lt \$MAX_RETRY ]; do
        _nic_data=\$(awk -v nic="\${NIC}:" '\$0 ~ nic {gsub(/:/, " "); print \$2,\$10; exit}' /proc/net/dev)
        if [ -n "\$_nic_data" ]; then
            echo "\$_nic_data"
            return 0
        fi
        _retry=\$((\$_retry + 1))
        sleep 1
    done
    echo "0 0"
}

_count=0
for _s in \$SERVERS; do
    _count=\$((\$_count + 1))
    eval "LAST_PUSH_\$_count=0"
done

PREV_STATS=\$(get_cpu_stats)
[ -t 1 ] && DEBUG=1 || DEBUG=0

while true; do
    sleep 1
    NOW=\$(awk '{print int(\$1)}' /proc/uptime)

    CURR_STATS=\$(get_cpu_stats)
    set -- \$PREV_STATS; p_u=\$1 p_n=\$2 p_s=\$3 p_i=\$4 p_io=\$5 p_ir=\$6 p_so=\$7
    set -- \$CURR_STATS; c_u=\$1 c_n=\$2 c_s=\$3 c_i=\$4 c_io=\$5 c_ir=\$6 c_so=\$7
    total=\$(( (c_u-p_u)+(c_n-p_n)+(c_s-p_s)+(c_i-p_i)+(c_io-p_io)+(c_ir-p_ir)+(c_so-p_so) ))
    if [ "\$total" -gt 0 ]; then
        pc=\$(( (total - (c_i-p_i)) * 100 / total ))
        [ "\$pc" -gt 100 ] && pc=100
        if   [ "\$pc" -ge 100 ]; then CPU_USAGE="1.00"
        elif [ "\$pc" -lt 10  ]; then CPU_USAGE="0.0\${pc}"
        else                          CPU_USAGE="0.\${pc}"
        fi
    else
        CPU_USAGE="0.00"
    fi
    PREV_STATS=\$CURR_STATS

    M_TOTAL=\$(awk '/^MemTotal:/{print int(\$2/1024)}' /proc/meminfo)
    M_AVAIL=\$(awk '/^MemAvailable:/{print int(\$2/1024)}' /proc/meminfo)
    M_USED=\$((M_TOTAL - M_AVAIL))
    [ "\$M_USED" -lt 0 ] && M_USED=0
    UPTIME=\$(awk '{print int(\$1)}' /proc/uptime)
    D_INFO=\$(df -Pm / | tail -n 1)
    D_TOTAL=\$(echo "\$D_INFO" | awk '{print \$2}')
    D_USED=\$(echo "\$D_INFO"  | awk '{print \$3}')

    NET_STATS=\$(get_net_stats)
    NET_RX=\$(echo "\$NET_STATS" | awk '{print \$1}')
    NET_TX=\$(echo "\$NET_STATS" | awk '{print \$2}')
    NET_REPORT="\${NET_RX},\${NET_TX}"

    PROCESS_COUNT=\$(ps -ef | wc -l)
    TCP_CONN=\$(grep -v "local_address" /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l)
    UDP_CONN=\$(grep -v "local_address" /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)

    BASE_DATA="id=\${ID}&uptime=\${UPTIME}&load=\${CPU_USAGE}&mem=\${M_TOTAL},\${M_USED}&disk=\${D_TOTAL},\${D_USED}&net=\${NET_REPORT}&process=\${PROCESS_COUNT}&tcp=\${TCP_CONN}&udp=\${UDP_CONN}&arch=\${ARCH}&os=\${OS}&region=\${REGION}&cpu_name=\${CPU_NAME}"

    _idx=0
    for _item in \$SERVERS; do
        _idx=\$((\$_idx + 1))
        _url=\$(echo "\$_item"   | cut -d'|' -f1)
        _token=\$(echo "\$_item" | cut -d'|' -f2)
        _iv=\$(echo "\$_item"    | cut -d'|' -f3)
        eval "_last=\\\$LAST_PUSH_\$_idx"
        if [ "\$(( NOW - _last ))" -ge "\$_iv" ]; then
            POST_DATA="token=\${_token}&\${BASE_DATA}"
            if [ "\$DEBUG" -eq 1 ]; then
                echo "[\$(date '+%H:%M:%S')] 推送[\$_idx] \$_url"
                echo "[\$(date '+%H:%M:%S')] NIC:\$NIC  RX:\${NET_RX}B  TX:\${NET_TX}B  CPU:\${CPU_USAGE}  MEM:\${M_USED}/\${M_TOTAL}MB"
            fi
            curl -sk --max-time 5 -X POST "\$_url" -d "\$POST_DATA" >/dev/null 2>&1
            eval "LAST_PUSH_\$_idx=\$NOW"
        fi
    done
done
AGENT_EOF

    chmod +x "$AGENT_FILE"
    ok "已生成：$AGENT_FILE"
}

# =============================================
# 5. 停止旧进程
# =============================================
stop_old() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            info "停止旧进程 (PID: $OLD_PID)"
            kill "$OLD_PID" 2>/dev/null
            sleep 1
        fi
        rm -f "$PID_FILE"
    fi
    OLD=$(pgrep -f "agent.sh" 2>/dev/null)
    [ -n "$OLD" ] && kill $OLD 2>/dev/null && sleep 1
}

# =============================================
# 6. 后台启动
# =============================================
start_agent() {
    title "启动 agent"
    stop_old
    nohup sh "$AGENT_FILE" >> "$LOG_FILE" 2>&1 &
    AGENT_PID=$!
    echo $AGENT_PID > "$PID_FILE"
    sleep 1
    if kill -0 $AGENT_PID 2>/dev/null; then
        ok "启动成功，PID: $AGENT_PID"
    else
        error "启动失败，请查看日志：$LOG_FILE"
    fi
}

# =============================================
# 7. 打印摘要
# =============================================
print_summary() {
    title "安装完成"
    printf "\n"
    printf "  ${BOLD}节点 ID   :${NC} %s\n" "$NODE_ID"
    printf "  ${BOLD}区域      :${NC} %s\n" "$NODE_REGION"
    printf "  ${BOLD}网卡      :${NC} %s\n" "$FINAL_NIC"
    printf "  ${BOLD}推送地址  :${NC} %s\n" "$PUSH_URL"
    printf "  ${BOLD}脚本路径  :${NC} %s\n" "$AGENT_FILE"
    printf "  ${BOLD}日志文件  :${NC} %s\n" "$LOG_FILE"
    printf "\n"
    printf "  ${BOLD}常用命令：${NC}\n"
    printf "  停止:   kill \$(cat %s)\n" "$PID_FILE"
    printf "  日志:   tail -f %s\n"     "$LOG_FILE"
    printf "  调试:   sh %s\n"          "$AGENT_FILE"
    printf "\n"
}

# =============================================
# 主流程
# =============================================
printf "\n${BOLD}${CYAN}========================================${NC}\n"
printf "${BOLD}${CYAN}   监控 Agent 安装脚本${NC}\n"
printf "${BOLD}${CYAN}========================================${NC}\n\n"

detect_os
detect_region
detect_nic
generate_agent
start_agent
print_summary
