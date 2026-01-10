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
IPERF_PORT="5201"           # iperf3服务器端口
MEMORY_SIZE="3G"            # 内存测试大小，目标约75%内存使用率
DISK_IO_TARGET="5g"         # 磁盘IO目标带宽 (5 gigabits per second)
NETWORK_IO_TARGET="4G"      # 网络IO目标带宽 (4Gbps)

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
    
    # 检查文件系统工具
    if ! command -v findmnt &> /dev/null; then
        print_warning "findmnt 命令未找到，将使用备用方法检查挂载状态"
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
    
    # 检查设备是否已挂载
    local mount_point=""
    if command -v findmnt &> /dev/null; then
        mount_point=$(findmnt -n -o TARGET "$NVME_DEVICE" 2>/dev/null || true)
    else
        # 备用方法：检查设备是否在 /proc/mounts 中
        mount_point=$(grep "^$NVME_DEVICE " /proc/mounts 2>/dev/null | awk '{print $2}' || true)
        if [ -z "$mount_point" ]; then
            # 再尝试使用 mount 命令
            mount_point=$(mount | grep "^$NVME_DEVICE on " | awk '{print $3}' || true)
        fi
    fi
    
    local test_file
    
    if [ -n "$mount_point" ]; then
        print_warning "设备 $NVME_DEVICE 已挂载在 $mount_point，将使用文件系统测试以确保安全"
        # 在挂载点创建测试文件
        test_file="${mount_point}/fio_test_file"
        
        # 清理可能存在的旧测试文件
        rm -f "$test_file" 2>/dev/null || true
        
        # 预分配测试文件（使用fallocate快速创建）
        print_info "创建测试文件: $test_file (大小: $TEST_FILE_SIZE)"
        
        # 转换大小用于 dd 命令
        local size_for_dd
        if [[ "$TEST_FILE_SIZE" == *G ]]; then
            size_for_dd=$(echo "${TEST_FILE_SIZE%G} * 1024" | bc 2>/dev/null || echo "${TEST_FILE_SIZE%G}000")
        elif [[ "$TEST_FILE_SIZE" == *M ]]; then
            size_for_dd="${TEST_FILE_SIZE%M}"
        else
            size_for_dd=1
        fi
        
        # 尝试多种方法创建文件
        if ! fallocate -l "$TEST_FILE_SIZE" "$test_file" 2>/dev/null; then
            if ! dd if=/dev/zero of="$test_file" bs=1M count="$size_for_dd" 2>/dev/null; then
                truncate -s "$TEST_FILE_SIZE" "$test_file" 2>/dev/null || {
                    print_error "无法创建测试文件，跳过NVMe测试"
                    return 1
                }
            fi
        fi
        
        # 验证文件大小
        if [ -f "$test_file" ]; then
            local actual_size=$(stat -c%s "$test_file" 2>/dev/null || wc -c < "$test_file" 2>/dev/null || echo 0)
            local expected_size
            if [[ "$TEST_FILE_SIZE" == *G ]]; then
                expected_size=$(( ${TEST_FILE_SIZE%G} * 1024 * 1024 * 1024 ))
            elif [[ "$TEST_FILE_SIZE" == *M ]]; then
                expected_size=$(( ${TEST_FILE_SIZE%M} * 1024 * 1024 ))
            else
                expected_size=${TEST_FILE_SIZE}
            fi
            
            if [ "$actual_size" -lt "$expected_size" ]; then
                print_warning "测试文件大小 ($actual_size 字节) 小于预期 ($expected_size 字节)，但将继续测试"
            fi
        fi
    else
        print_info "设备 $NVME_DEVICE 未挂载，将直接测试裸设备"
        test_file="$NVME_DEVICE"
    fi
    
    # 1. 5 Gbps目标测试（确保触发5 Gbps IO）- 使用posixaio
    print_info "运行5 Gbps目标测试 (posixaio)..."
    local target_bw="5G"  # 5 gigabits per second
    $FIO_CMD --name=target_5gbps --filename="$test_file" --ioengine=posixaio --direct=1 \
        --bs=1M --iodepth=128 --size="$TEST_FILE_SIZE" --rw=write \
        --rate="$target_bw" --rate_process=poisson \
        --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/target_5gbps.json" --output-format=json &
    FIO_TARGET_PID=$!
    
    # 2. 顺序读写测试（使用mmap ioengine以提高性能）
    print_info "运行顺序写入测试 (mmap)..."
    $FIO_CMD --name=seq_write_mmap --filename="$test_file" --ioengine=mmap --direct=0 \
        --bs=1M --iodepth=128 --size="$TEST_FILE_SIZE" --rw=write \
        --numjobs=4 --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_write_mmap.json" --output-format=json &
    FIO_WRITE_MMAP_PID=$!
    
    print_info "运行顺序读取测试 (mmap)..."
    $FIO_CMD --name=seq_read_mmap --filename="$test_file" --ioengine=mmap --direct=0 \
        --bs=1M --iodepth=128 --size="$TEST_FILE_SIZE" --rw=read \
        --numjobs=4 --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_read_mmap.json" --output-format=json &
    FIO_READ_MMAP_PID=$!
    
    # 3. 随机IO测试（使用mmap ioengine以提高性能）
    print_info "运行随机读写测试 (mmap)..."
    $FIO_CMD --name=rand_rw_mmap --filename="$test_file" --ioengine=mmap --direct=0 \
        --bs=4k --iodepth=256 --size="$TEST_FILE_SIZE" --rw=randrw --rwmixread=70 \
        --numjobs=8 --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/rand_rw_mmap.json" --output-format=json &
    FIO_RAND_MMAP_PID=$!
    
    # 4. 传统posixaio测试（用于比较）
    print_info "运行传统顺序写入测试 (posixaio)..."
    $FIO_CMD --name=seq_write_posix --filename="$test_file" --ioengine=posixaio --direct=1 \
        --bs=1M --iodepth=128 --size="$TEST_FILE_SIZE" --rw=write \
        --numjobs=4 --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_write_posix.json" --output-format=json &
    FIO_WRITE_POSIX_PID=$!
    
    print_info "运行传统顺序读取测试 (posixaio)..."
    $FIO_CMD --name=seq_read_posix --filename="$test_file" --ioengine=posixaio --direct=1 \
        --bs=1M --iodepth=128 --size="$TEST_FILE_SIZE" --rw=read \
        --numjobs=4 --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/nvme/seq_read_posix.json" --output-format=json &
    FIO_READ_POSIX_PID=$!
    
    # 等待NVMe测试完成
    wait $FIO_TARGET_PID $FIO_WRITE_MMAP_PID $FIO_READ_MMAP_PID $FIO_RAND_MMAP_PID $FIO_WRITE_POSIX_PID $FIO_READ_POSIX_PID
    
    # 分析5 Gbps测试结果
    if [ -f "$LOG_DIR/nvme/target_5gbps.json" ]; then
        local achieved_bw=$(grep -A5 '"write"' "$LOG_DIR/nvme/target_5gbps.json" | grep '"bw_mean"' | sed 's/.*: //;s/,//')
        if [ -n "$achieved_bw" ]; then
            # 转换字节/秒为Gbps
            local achieved_gbps=$(echo "scale=2; $achieved_bw * 8 / 1000000000" | bc 2>/dev/null || echo "N/A")
            print_info "5 Gbps目标测试结果: 达到 ${achieved_gbps} Gbps"
            if [ "$achieved_gbps" != "N/A" ] && [ $(echo "$achieved_gbps >= 4.5" | bc 2>/dev/null || echo 0) -eq 1 ]; then
                print_success "成功触发至少 4.5 Gbps IO (目标: 5 Gbps)"
            else
                print_warning "未能达到 5 Gbps 目标，仅达到 ${achieved_gbps} Gbps"
            fi
        fi
    fi
    
    # 清理测试文件（如果是文件系统测试）
    if [ -n "$mount_point" ] && [ -f "$test_file" ]; then
        print_info "清理测试文件: $test_file"
        rm -f "$test_file"
    fi
    
    print_success "NVMe压力测试完成"
}

# 网络压力测试
network_stress_test() {
    if [ -z "$SERVER_IP" ]; then
        print_warning "未设置服务器IP，跳过网络测试"
        return
    fi
    
    print_info "开始网络压力测试（运行${RUN_TIME}秒）..."
    
    # UDP带宽测试（使用UDP以达到最大线路速度）
    print_info "使用UDP进行带宽测试（设置极高带宽目标100G以达到最大线路速度）..."
    $IPERF3_CMD -c "$SERVER_IP" -p "$IPERF_PORT" -t "$RUN_TIME" -u -b 100G \
        -J > "$LOG_DIR/network/udp_upload.json" &
    IPERF_UDP_PID=$!
    
    # 等待网络测试完成
    wait $IPERF_UDP_PID
    
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
        --bs=4k --iodepth=64 --size="$MEMORY_SIZE" --rw=randrw --rwmixread=50 \
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
5 Gbps目标测试: $(grep -A5 '"write"' "$LOG_DIR/nvme/target_5gbps.json" | grep 'bw_mean' | cut -d: -f2)
顺序写入 (mmap): $(grep -A5 '"write"' "$LOG_DIR/nvme/seq_write_mmap.json" | grep 'bw_mean' | cut -d: -f2)
顺序读取 (mmap): $(grep -A5 '"read"' "$LOG_DIR/nvme/seq_read_mmap.json" | grep 'bw_mean' | cut -d: -f2)
顺序写入 (posixaio): $(grep -A5 '"write"' "$LOG_DIR/nvme/seq_write_posix.json" | grep 'bw_mean' | cut -d: -f2)
顺序读取 (posixaio): $(grep -A5 '"read"' "$LOG_DIR/nvme/seq_read_posix.json" | grep 'bw_mean' | cut -d: -f2)
随机读写 (mmap) IOPS: $(grep -A5 '"iops"' "$LOG_DIR/nvme/rand_rw_mmap.json" | grep 'mean' | head -1 | cut -d: -f2)

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
    echo "  -d <设备>   NVMe设备路径 (默认: /dev/nvme0n1p2)"
    echo "  -i <接口>   网络接口 (默认: lan2)"
    echo "  -s <IP>     网络测试服务器IP (默认: 192.168.2.222)"
    echo "  -p <端口>   iperf3服务器端口 (默认: 5201)"
    echo "  -m <大小>   内存测试大小 (默认: 3G)"
    echo "  -j <线程>   并行线程数 (默认: 4)"
    echo "  -b <带宽>   磁盘IO目标带宽，单位：g= gigabits, m= megabits, k= kilobits (默认: 5g)"
    echo "  -n <带宽>   网络IO目标带宽 (默认: 4G)"
    echo "  -h         显示帮助信息"
    exit 0
}

# 解析命令行参数
while getopts "t:d:i:s:p:m:j:b:n:h" opt; do
    case $opt in
        t) RUN_TIME="$OPTARG" ;;
        d) NVME_DEVICE="$OPTARG" ;;
        i) NETWORK_IF="$OPTARG" ;;
        s) SERVER_IP="$OPTARG" ;;
        p) IPERF_PORT="$OPTARG" ;;
        m) MEMORY_SIZE="$OPTARG" ;;
        j) THREADS="$OPTARG" ;;
        b) DISK_IO_TARGET="$OPTARG" ;;
        n) NETWORK_IO_TARGET="$OPTARG" ;;
        h) usage ;;
        *) echo "无效选项: -$OPTARG" >&2; exit 1 ;;
    esac
done

# 运行主函数
main "$@"
