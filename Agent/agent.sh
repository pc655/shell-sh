#!/bin/sh
# === 配置区 ===
ID="Alpine-128M"
TOKEN="admin888"
URLS="https://tz.995566.xyz/push.php"
INTERVAL=2

get_stats() {
    grep '^cpu ' /proc/stat | awk '{print $2" "$3" "$4" "$5" "$6" "$7" "$8}'
}
PREV_STATS=$(get_stats)
while true; do
    sleep $INTERVAL
    # --- 1. CPU ---
    CURR_STATS=$(get_stats)
    set -- $PREV_STATS
    p_u=$1; p_n=$2; p_s=$3; p_i=$4; p_io=$5; p_ir=$6; p_so=$7
    set -- $CURR_STATS
    c_u=$1; c_n=$2; c_s=$3; c_i=$4; c_io=$5; c_ir=$6; c_so=$7
    du=$((c_u-p_u)); dn=$((c_n-p_n)); ds=$((c_s-p_s))
    di=$((c_i-p_i)); dio=$((c_io-p_io)); dir=$((c_ir-p_ir)); dso=$((c_so-p_so))
    total=$((du+dn+ds+di+dio+dir+dso))
    if [ "$total" -gt 0 ]; then
        used=$((total - di))
        pc=$((used * 100 / total))
        [ "$pc" -gt 100 ] && pc=100
        if [ "$pc" -ge 100 ]; then
            CPU_USAGE="1.00"
        elif [ "$pc" -lt 10 ]; then
            CPU_USAGE="0.0${pc}"
        else
            CPU_USAGE="0.${pc}"
        fi
    else
        CPU_USAGE="0.00"
    fi
    PREV_STATS=$CURR_STATS
    # --- 2. 内存 ---
    M_INFO=$(cat /proc/meminfo)
    M_TOTAL=$(echo "$M_INFO" | awk '/^MemTotal:/{print int($2/1024)}')
    M_FREE=$(echo  "$M_INFO" | awk '/^MemFree:/{print int($2/1024)}')
    M_BUFF=$(echo  "$M_INFO" | awk '/^Buffers:/{print int($2/1024)}')
    M_CACH=$(echo  "$M_INFO" | awk '/^Cached:/{print int($2/1024)}')
    [ -z "$M_BUFF" ] && M_BUFF=0
    [ -z "$M_CACH" ] && M_CACH=0
    M_USED=$((M_TOTAL - M_FREE - M_BUFF - M_CACH))
    [ "$M_USED" -lt 0 ] && M_USED=0
    # --- 3. 运行时间 ---
    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    # --- 4. 磁盘 ---
    D_INFO=$(df -Pm / | tail -n 1)
    D_TOTAL=$(echo "$D_INFO" | awk '{print $2}')
    D_USED=$(echo  "$D_INFO" | awk '{print $3}')
    # --- 5. 网络 ---
    NET_RAW=$(awk '/:/{
        gsub(/:/, " ")
        if ($1 != "lo") { rx += $2; tx += $10 }
    } END { print rx","tx }' /proc/net/dev)
    # --- 6. 推送 ---
    for U in $URLS; do
        (RESULT=$(curl -sk -X POST "$U" \
            -d "token=$TOKEN" \
            -d "id=$ID" \
            -d "uptime=$UPTIME" \
            -d "load=$CPU_USAGE" \
            -d "mem=$M_TOTAL,$M_USED" \
            -d "disk=$D_TOTAL,$D_USED" \
            -d "net=$NET_RAW")
        echo "[$U] 返回: $RESULT | CPU: $CPU_USAGE | MEM: ${M_USED}/${M_TOTAL}MB | $(date +%H:%M:%S)") &
    done
    wait
done
