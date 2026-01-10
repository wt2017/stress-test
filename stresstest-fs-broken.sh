#!/bin/bash

# 综合压力测试脚本：同时测试 NVMe、NIC 和 Memory
# 文件名：stress_all.sh

set -e

# 配置参数
LOG_DIR="./stress_logs"
RUN_TIME=300  # 每个测试运行时间（秒）
NVME_DEVICE="/dev/nvme0n1p2"  # NVMe设备，请根据实际情况修改
TEST_FILE_SIZE="10G"        # 测试文件大小
THREADS=4                   # 并行线程数
NETWORK_IF="lan2"           # 网络接口，请根据实际情况修改
SERVER_IP="192.168.2.222"                # 网络测试服务器IP（留空则不进行网络测试）
MEMORY_SIZE="3G"            # 内存测试大小

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查必要工具并设置命令路径
check_dependencies() {
    local missing=()
    
    # 设置命令路径变量
    if command -v fio &> /dev/null; then
        FIO_CMD="fio"
    elif [ -x "./fio" ]; then
        FIO_CMD="./fio"
    else
        missing+=("fio")
    fi

    if command -v iperf3 &> /dev/null; then
        IPERF3_CMD="iperf3"
    elif [ -x "./iperf3" ]; then
        IPERF3_CMD="./iperf3"
    else
        missing+=("iperf3")
    fi

    if command -v stress-ng &> /dev/null; then
        STRESS_NG_CMD="stress-ng"
    elif [ -x "./stress-ng" ]; then
        STRESS_NG_CMD="./stress-ng"
    else
        missing+=("stress-ng")
    fi

    if ! command -v sar &> /dev/null; then
        missing+=("sysstat")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "缺少必要的工具: ${missing[*]}"
        echo "请安装:"
        echo "  Ubuntu/Debian: sudo apt-get install fio iperf3 stress-ng sysstat"
        echo "  RHEL/CentOS: sudo yum install fio iperf3 stress-ng sysstat"
        exit 1
    fi
}

# 创建日志目录
create_log_dir() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOG_DIR/nvme"
    mkdir -p "$LOG_DIR/network"
    mkdir -p "$LOG_DIR/memory"
    mkdir -p "$LOG_DIR/system"
}

# 系统监控（后台运行）
start_monitoring() {
    print_info "启动系统监控..."
    
    # CPU、内存、IO监控
    sar -u 1 > "$LOG_DIR/system/cpu.log" 2>&1 &
    SAR_CPU_PID=$!
    
    sar -r 1 > "$LOG_DIR/system/memory.log" 2>&1 &
    SAR_MEM_PID=$!
    
    sar -d 1 > "$LOG_DIR/system/disk.log" 2>&1 &
    SAR_DISK_PID=$!
    
    # 网络监控
    sar -n DEV 1 > "$LOG_DIR/system/network.log" 2>&1 &
    SAR_NET_PID=$!
}

# 停止监控
stop_monitoring() {
    print_info "停止系统监控..."
    kill $SAR_CPU_PID $SAR_MEM_PID $SAR_DISK_PID $SAR_NET_PID 2>/dev/null || true
}

# NVMe压力测试
nvme_stress_test() {
    print_info "开始NVMe压力测试（运行${RUN_TIME}秒）..."
    
    # 1. 顺序读写测试
    $FIO_CMD --name=seq_write --filename="$NVME_DEVICE" --ioengine=posixaio --direct=1 \
        --allow_mounted_write=1 --bs=1M --iodepth=32 --size="$TEST_FILE_SIZE" --rw=write \
        --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_write.json" --output-format=json &
    FIO_WRITE_PID=$!
    
    $FIO_CMD --name=seq_read --filename="$NVME_DEVICE" --ioengine=posixaio --direct=1 \
        --allow_mounted_write=1 --bs=1M --iodepth=32 --size="$TEST_FILE_SIZE" --rw=read \
        --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_read.json" --output-format=json &
    FIO_READ_PID=$!
    
    # 2. 随机IO测试
    $FIO_CMD --name=rand_rw --filename="$NVME_DEVICE" --ioengine=posixaio --direct=1 \
        --allow_mounted_write=1 --bs=4k --iodepth=64 --size="$TEST_FILE_SIZE" --rw=randrw --rwmixread=70 \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/rand_rw.json" --output-format=json &
    FIO_RAND_PID=$!
    
    # 等待NVMe测试完成
    wait $FIO_WRITE_PID $FIO_READ_PID $FIO_RAND_PID
    
    print_success "NVMe压力测试完成"
}

# 网络压力测试
network_stress_test() {
    if [ -z "$SERVER_IP" ]; then
        print_warning "未设置服务器IP，跳过网络测试"
        return
    fi
    
    print_info "开始网络压力测试（运行${RUN_TIME}秒）..."
    
    # TCP带宽测试
    $IPERF3_CMD -c "$SERVER_IP" -t "$RUN_TIME" -P "$THREADS" \
        -J > "$LOG_DIR/network/tcp_upload.json" &
    IPERF_TCP_UPLOAD_PID=$!
    
    sleep 2
    
    # UDP带宽测试
    $IPERF3_CMD -c "$SERVER_IP" -t "$RUN_TIME" -u -b 10G \
        -J > "$LOG_DIR/network/udp_upload.json" &
    IPERF_UDP_PID=$!
    
    # 等待网络测试完成
    wait $IPERF_TCP_UPLOAD_PID $IPERF_UDP_PID
    
    print_success "网络压力测试完成"
}

# 内存压力测试
memory_stress_test() {
    print_info "开始内存压力测试（运行${RUN_TIME}秒）..."
    
    # 使用stress-ng进行内存压力测试
    # --vm-bytes: 每个worker使用的内存大小
    # --vm-hang: 内存操作后暂停时间
    # --vm-keep: 保持内存分配不释放
    $STRESS_NG_CMD --vm "$THREADS" --vm-bytes "$MEMORY_SIZE" --vm-method all \
        --timeout "${RUN_TIME}s" --metrics-brief \
        > "$LOG_DIR/memory/stress_ng.log" 2>&1 &
    STRESS_NG_PID=$!
    
    # 使用fio进行内存IO测试
    $FIO_CMD --name=mem_test --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=32 --size="$MEMORY_SIZE" --rw=randrw --rwmixread=50 \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/memory/mem_io.json" --output-format=json &
    FIO_MEM_PID=$!
    
    # 等待内存测试完成
    wait $STRESS_NG_PID $FIO_MEM_PID
    
    print_success "内存压力测试完成"
}

# 并行运行所有测试
run_all_tests_parallel() {
    print_info "开始并行压力测试..."
    print_info "测试持续时间: ${RUN_TIME}秒"
    print_info "日志目录: ${LOG_DIR}"
    
    # 启动系统监控
    start_monitoring
    
    # 并行运行三个测试
    nvme_stress_test &
    NVME_PID=$!
    
    network_stress_test &
    NETWORK_PID=$!
    
    memory_stress_test &
    MEMORY_PID=$!
    
    # 显示进度
    for i in $(seq 1 "$RUN_TIME"); do
        echo -ne "测试进度: $i/${RUN_TIME} 秒\r"
        sleep 1
    done
    echo
    
    # 等待所有测试完成
    wait $NVME_PID $NETWORK_PID $MEMORY_PID
    
    # 停止监控
    stop_monitoring
}

# 生成测试报告
generate_report() {
    print_info "生成测试报告..."
    
    REPORT_FILE="$LOG_DIR/stress_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$REPORT_FILE" << EOF
综合压力测试报告
生成时间: $(date)
测试持续时间: ${RUN_TIME}秒
系统信息: $(uname -a)

=== 系统概览 ===
$(top -bn1 | head -20)

=== CPU使用率 ===
$(sar -u -f "$LOG_DIR/system/cpu.log" | tail -10)

=== 内存使用情况 ===
$(sar -r -f "$LOG_DIR/system/memory.log" | tail -10)

=== 磁盘IO统计 ===
$(sar -d -f "$LOG_DIR/system/disk.log" | tail -10)

=== 网络统计 ===
$(sar -n DEV -f "$LOG_DIR/system/network.log" | tail -10)

=== NVMe测试摘要 ===
顺序写入: $(grep -A5 '"write"' "$LOG_DIR/nvme/seq_write.json" | grep 'bw_mean' | cut -d: -f2)
顺序读取: $(grep -A5 '"read"' "$LOG_DIR/nvme/seq_read.json" | grep 'bw_mean' | cut -d: -f2)
随机读写IOPS: $(grep -A5 '"iops"' "$LOG_DIR/nvme/rand_rw.json" | grep 'mean' | head -1 | cut -d: -f2)

=== 测试状态 ===
所有测试完成: ✓
错误检查: $(if [ $? -eq 0 ]; then echo "无错误"; else echo "发现错误"; fi)

=== 建议 ===
1. 检查日志文件查看详细结果
2. 比较不同时间点的测试结果
3. 监控系统温度确保没有过热
EOF
    
    print_success "报告已生成: $REPORT_FILE"
    
    # 显示简要结果
    echo -e "\n${GREEN}=== 测试完成 ===${NC}"
    echo "详细日志请查看: $LOG_DIR"
    echo "测试报告: $REPORT_FILE"
}

# 清理函数
cleanup() {
    print_info "执行清理..."
    
    # 停止所有子进程
    pkill -f "fio" 2>/dev/null || true
    pkill -f "iperf3" 2>/dev/null || true
    pkill -f "stress-ng" 2>/dev/null || true
    pkill -f "sar" 2>/dev/null || true
    
    # 等待进程结束
    sleep 2
}

# 主函数
main() {
    # 设置trap捕获中断信号
    trap cleanup EXIT INT TERM
    
    print_info "开始综合压力测试"
    
    # 检查依赖
    check_dependencies
    
    # 创建日志目录
    create_log_dir
    
    # 运行测试
    run_all_tests_parallel
    
    # 生成报告
    generate_report
    
    print_success "所有压力测试完成！"
}

# 脚本用法
usage() {
    echo "使用方法: $0 [选项]"
    echo "选项:"
    echo "  -t <秒>     测试运行时间 (默认: 300)"
    echo "  -d <设备>   NVMe设备路径 (默认: /dev/nvme0n1)"
    echo "  -i <接口>   网络接口 (默认: eth0)"
    echo "  -s <IP>     网络测试服务器IP"
    echo "  -m <大小>   内存测试大小 (默认: 8G)"
    echo "  -j <线程>   并行线程数 (默认: 4)"
    echo "  -h         显示帮助信息"
    exit 0
}

# 解析命令行参数
while getopts "t:d:i:s:m:j:h" opt; do
    case $opt in
        t) RUN_TIME="$OPTARG" ;;
        d) NVME_DEVICE="$OPTARG" ;;
        i) NETWORK_IF="$OPTARG" ;;
        s) SERVER_IP="$OPTARG" ;;
        m) MEMORY_SIZE="$OPTARG" ;;
        j) THREADS="$OPTARG" ;;
        h) usage ;;
        *) echo "无效选项: -$OPTARG" >&2; exit 1 ;;
    esac
done

# 运行主函数
main "$@"
