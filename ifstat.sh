#!/bin/bash
# monitor_bps_10s.sh

INTERFACES="lan3 lan4 lan5 lan6"
STAT_INTERVAL=10  # 统计间隔10秒

echo "=== 物理层带宽监控（10秒平均）==="
echo "监控网口: $INTERFACES"
echo "统计间隔: ${STAT_INTERVAL}秒"
echo "开始时间: $(date)"
echo ""

# 初始化存储
declare -A start_rx_bytes start_tx_bytes
declare -A total_rx_bytes total_tx_bytes
declare -A rx_packets tx_packets
declare -A last_success

# 检查网口是否存在并获取初始值
for iface in $INTERFACES; do
    if [ -d "/sys/class/net/$iface" ]; then
        echo "✅ 找到网口: $iface"
        start_rx_bytes[$iface]=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        start_tx_bytes[$iface]=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        rx_packets[$iface]=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null || echo 0)
        tx_packets[$iface]=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null || echo 0)
        total_rx_bytes[$iface]=0
        total_tx_bytes[$iface]=0
        last_success[$iface]=1
    else
        echo "❌ 网口不存在: $iface"
        last_success[$iface]=0
    fi
done
echo ""

# 格式转换函数
format_bps() {
    local bps=$1
    if [ $bps -ge 1000000000 ]; then
        echo "$(($bps/1000000000)) Gbps"
    elif [ $bps -ge 1000000 ]; then
        echo "$(($bps/1000000)) Mbps"
    elif [ $bps -ge 1000 ]; then
        echo "$(($bps/1000)) Kbps"
    else
        echo "$bps bps"
    fi
}

format_pps() {
    local pps=$1
    if [ $pps -ge 1000000 ]; then
        echo "$(($pps/1000000)) Mpps"
    elif [ $pps -ge 1000 ]; then
        echo "$(($pps/1000)) Kpps"
    else
        echo "$pps pps"
    fi
}

# 监控循环
while true; do
    echo "===== 开始 ${STAT_INTERVAL}秒统计周期 $(date '+%H:%M:%S') ====="
    echo ""
    
    # 等待统计周期
    echo "正在采集数据..."
    sleep $STAT_INTERVAL
    
    echo ""
    echo "=== 统计结果（${STAT_INTERVAL}秒平均）==="
    printf "%-8s %-20s %-20s %-15s %-15s %-12s\n" \
           "网口" "接收速率" "发送速率" "收包率" "发包率" "状态"
    echo "------------------------------------------------------------------------------------------------"
    
    for iface in $INTERFACES; do
        if [ ${last_success[$iface]} -eq 0 ]; then
            printf "%-8s %-20s %-20s %-15s %-15s %-12s\n" \
                   "$iface" "N/A" "N/A" "N/A" "N/A" "❌ 网口不存在"
            continue
        fi
        
        # 读取结束值
        end_rx_bytes=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        end_tx_bytes=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        end_rx_packets=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null || echo 0)
        end_tx_packets=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null || echo 0)
        
        if [ "$end_rx_bytes" = "0" ] && [ "$end_tx_bytes" = "0" ]; then
            printf "%-8s %-20s %-20s %-15s %-15s %-12s\n" \
                   "$iface" "N/A" "N/A" "N/A" "N/A" "⚠️  读取失败"
            last_success[$iface]=0
            continue
        fi
        
        # 计算增量
        rx_bytes_diff=$((end_rx_bytes - start_rx_bytes[$iface]))
        tx_bytes_diff=$((end_tx_bytes - start_tx_bytes[$iface]))
        rx_packets_diff=$((end_rx_packets - rx_packets[$iface]))
        tx_packets_diff=$((end_tx_packets - tx_packets[$iface]))
        
        # 计算平均速率（10秒平均）
        rx_bps=$((rx_bytes_diff * 8 / STAT_INTERVAL))
        tx_bps=$((tx_bytes_diff * 8 / STAT_INTERVAL))
        rx_pps=$((rx_packets_diff / STAT_INTERVAL))
        tx_pps=$((tx_packets_diff / STAT_INTERVAL))
        
        # 更新累计流量
        total_rx_bytes[$iface]=$((total_rx_bytes[$iface] + rx_bytes_diff))
        total_tx_bytes[$iface]=$((total_tx_bytes[$iface] + tx_bytes_diff))
        
        # 更新起始值
        start_rx_bytes[$iface]=$end_rx_bytes
        start_tx_bytes[$iface]=$end_tx_bytes
        rx_packets[$iface]=$end_rx_packets
        tx_packets[$iface]=$end_tx_packets
        
        # 格式化输出
        printf "%-8s %-20s %-20s %-15s %-15s %-12s\n" \
               "$iface" \
               "$(format_bps $rx_bps)" \
               "$(format_bps $tx_bps)" \
               "$(format_pps $rx_pps)" \
               "$(format_pps $tx_pps)" \
               "✅ 正常"
    done
    
    echo ""
    echo "=== 累计流量 ==="
    for iface in $INTERFACES; do
        if [ ${last_success[$iface]} -eq 1 ]; then
            rx_mb=$((${total_rx_bytes[$iface]} / 1048576))
            tx_mb=$((${total_tx_bytes[$iface]} / 1048576))
            echo "  $iface: 接收 ${rx_mb} MB, 发送 ${tx_mb} MB"
        fi
    done
    
    echo ""
    echo "========================================"
    echo ""
done

