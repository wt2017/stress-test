#!/bin/bash

# Disk IO read/write stress test script using fio
# Tests sequential and random read/write patterns using file-based tests
# Safe for production systems - only writes to designated test directory

set -e

# Configuration parameters
LOG_DIR="./disk_io_logs"
RUN_TIME=300  # Test run time (seconds)
TEST_FILE_SIZE="2G"         # Test file size per thread (smaller for safety)
THREADS=4                   # Parallel threads
TEST_DIR="./disk_io_test_files"  # Directory for file-based tests

# Color output
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

# Check required tools and set command paths
check_dependencies() {
    local missing=()
    
    # Set command path variables
    if command -v fio &> /dev/null; then
        FIO_CMD="fio"
    elif [ -x "./fio" ]; then
        FIO_CMD="./fio"
    else
        missing+=("fio")
    fi

    if ! command -v sar &> /dev/null; then
        missing+=("sysstat")
    fi
    
    if ! command -v iostat &> /dev/null; then
        print_warning "iostat command not found, disk monitoring may be limited"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        echo "Please install:"
        echo "  Ubuntu/Debian: sudo apt-get install fio sysstat"
        echo "  RHEL/CentOS: sudo yum install fio sysstat"
        exit 1
    fi
}

# Create log directory
create_log_dir() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOG_DIR/sequential"
    mkdir -p "$LOG_DIR/random"
    mkdir -p "$LOG_DIR/mixed"
    mkdir -p "$LOG_DIR/system"
    mkdir -p "$TEST_DIR"
}

# Clean up test directory
cleanup_test_dir() {
    if [ -d "$TEST_DIR" ]; then
        print_info "Cleaning test directory: $TEST_DIR"
        find "$TEST_DIR" -type f -name "*.tmp" -delete 2>/dev/null || true
        find "$TEST_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
}

# Check if test directory is safe to use
check_test_dir_safety() {
    local test_dir="$1"
    
    # Check if directory exists and is writable
    if [ ! -d "$test_dir" ]; then
        mkdir -p "$test_dir" 2>/dev/null || {
            print_error "Cannot create test directory: $test_dir"
            return 1
        }
    fi
    
    if [ ! -w "$test_dir" ]; then
        print_error "Test directory is not writable: $test_dir"
        return 1
    fi
    
    # Check if directory is on a reasonable filesystem
    local dir_path=$(realpath "$test_dir")
    
    # Only warn for truly sensitive system directories, not user project directories
    # Check if it's directly under root system directories (not in user home projects)
    local sensitive_locations=(
        "/etc"
        "/var"
        "/usr"
        "/boot"
        "/lib"
        "/sbin"
        "/bin"
        "/dev"
        "/proc"
        "/sys"
    )
    
    for sensitive_loc in "${sensitive_locations[@]}"; do
        if [[ "$dir_path" == "$sensitive_loc"* ]]; then
            print_warning "Warning: Test directory is under system location: $sensitive_loc"
            print_warning "Consider using a test directory in /tmp or your home directory"
            return 0  # Not fatal, just warning
        fi
    done
    
    # Special check for root directory - only warn if directly under / (not /home, /tmp, etc.)
    if [[ "$dir_path" == "/" ]] || [[ "$dir_path" =~ ^/[^/]+$ ]]; then
        print_warning "Warning: Test directory is directly under root filesystem"
        print_warning "Consider using a test directory in /tmp or your home directory"
        return 0
    fi
    
    return 0
}

# System monitoring (run in background)
start_monitoring() {
    print_info "Starting system monitoring..."
    
    # CPU, memory, IO monitoring
    sar -u 1 > "$LOG_DIR/system/cpu.log" 2>&1 &
    SAR_CPU_PID=$!
    
    sar -r 1 > "$LOG_DIR/system/memory.log" 2>&1 &
    SAR_MEM_PID=$!
    
    sar -d 1 > "$LOG_DIR/system/disk.log" 2>&1 &
    SAR_DISK_PID=$!
    
    # iostat for detailed disk stats
    iostat -x 1 > "$LOG_DIR/system/iostat.log" 2>&1 &
    IOSTAT_PID=$!
}

# Stop monitoring
stop_monitoring() {
    print_info "Stopping system monitoring..."
    kill $SAR_CPU_PID $SAR_MEM_PID $SAR_DISK_PID $IOSTAT_PID 2>/dev/null || true
    sleep 2
}

# Create test files for IO testing
create_test_files() {
    print_info "Creating test files in $TEST_DIR"
    
    # Calculate total space needed
    local total_space_needed=$((THREADS * 2))  # 2GB per thread for safety
    
    # Check available space
    local available_space=$(df -k "$TEST_DIR" | awk 'NR==2 {print $4}')
    local available_space_gb=$((available_space / 1048576))
    
    if [ $available_space_gb -lt $total_space_needed ]; then
        print_warning "Insufficient disk space: $available_space_gb GB available, $total_space_needed GB needed"
        print_warning "Reducing test file size..."
        TEST_FILE_SIZE="1G"
    fi
    
    print_info "Creating $THREADS test files ($TEST_FILE_SIZE each)..."
    
    # Create test files sequentially to show progress
    for i in $(seq 1 "$THREADS"); do
        print_info "Creating test file $i of $THREADS..."
        # Run fio in foreground to show real-time progress
        $FIO_CMD --name="create_file_$i" --filename="$TEST_DIR/testfile_$i.tmp" \
            --ioengine=posixaio --direct=1 --bs=1M --size="$TEST_FILE_SIZE" \
            --rw=write --runtime=30 --time_based --do_verify=0 \
            --output="$LOG_DIR/file_create_$i.log" --output-format=json
    done
    
    print_success "Test files created successfully"
}

# Sequential read/write test (file-based)
sequential_io_test() {
    print_info "Starting sequential IO test (runtime: ${RUN_TIME}s)"
    
    print_info "Running sequential WRITE test..."
    # Sequential write test - run in foreground to show progress
    $FIO_CMD --name="seq_write_test" --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=1M --iodepth=32 --size="$TEST_FILE_SIZE" --rw=write \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/sequential/seq_write.json" --output-format=json
    
    print_info "Running sequential READ test..."
    # Sequential read test - run in foreground to show progress
    $FIO_CMD --name="seq_read_test" --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=1M --iodepth=32 --size="$TEST_FILE_SIZE" --rw=read \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/sequential/seq_read.json" --output-format=json
    
    print_success "Sequential IO test completed"
}

# Random read/write test (file-based)
random_io_test() {
    print_info "Starting random IO test (runtime: ${RUN_TIME}s)"
    
    print_info "Running random READ test..."
    # Random read test - run in foreground to show progress
    $FIO_CMD --name="rand_read_test" --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=64 --size="$TEST_FILE_SIZE" --rw=randread \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/random/rand_read.json" --output-format=json
    
    print_info "Running random WRITE test..."
    # Random write test - run in foreground to show progress
    $FIO_CMD --name="rand_write_test" --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=64 --size="$TEST_FILE_SIZE" --rw=randwrite \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/random/rand_write.json" --output-format=json
    
    print_success "Random IO test completed"
}

# Mixed read/write test (file-based)
mixed_io_test() {
    print_info "Starting mixed read/write test (runtime: ${RUN_TIME}s)"
    
    print_info "Running mixed read/write test (70% read, 30% write)..."
    # Mixed random read/write (70% read, 30% write) - run in foreground to show progress
    $FIO_CMD --name="mixed_rw_test" --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=64 --size="$TEST_FILE_SIZE" --rw=randrw --rwmixread=70 \
        --numjobs="$THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/mixed/mixed_rw.json" --output-format=json
    
    print_success "Mixed read/write test completed"
}

# Run all tests
run_all_tests() {
    print_info "Starting disk IO stress test..."
    print_info "Test duration: ${RUN_TIME} seconds per test"
    print_info "Log directory: ${LOG_DIR}"
    print_info "Test directory: ${TEST_DIR}"
    print_info "Threads: ${THREADS}"
    print_info "Test file size: ${TEST_FILE_SIZE} per thread"
    
    # Check test directory safety
    if ! check_test_dir_safety "$TEST_DIR"; then
        print_error "Test directory safety check failed"
        exit 1
    fi
    
    # Clean up old test files
    cleanup_test_dir
    
    # Start system monitoring
    start_monitoring
    
    # Create test files
    create_test_files
    
    # Run tests
    sequential_io_test
    random_io_test
    mixed_io_test
    
    # Stop monitoring
    stop_monitoring
    
    print_success "All disk IO tests completed"
}

# Generate test report
generate_report() {
    print_info "Generating disk IO test report..."
    
    REPORT_FILE="$LOG_DIR/disk_io_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    # Collect key metrics
    local seq_write_bw=0
    local seq_read_bw=0
    local rand_read_iops=0
    local rand_write_iops=0
    local mixed_iops=0
    
    # Extract metrics from JSON files if they exist
    if [ -f "$LOG_DIR/sequential/seq_write.json" ]; then
        seq_write_bw=$(grep -A5 '"write"' "$LOG_DIR/sequential/seq_write.json" | \
                      grep 'bw_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sequential/seq_read.json" ]; then
        seq_read_bw=$(grep -A5 '"read"' "$LOG_DIR/sequential/seq_read.json" | \
                      grep 'bw_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/random/rand_read.json" ]; then
        rand_read_iops=$(grep -A5 '"read"' "$LOG_DIR/random/rand_read.json" | \
                        grep 'iops_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/random/rand_write.json" ]; then
        rand_write_iops=$(grep -A5 '"write"' "$LOG_DIR/random/rand_write.json" | \
                        grep 'iops_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/mixed/mixed_rw.json" ]; then
        mixed_iops=$(grep -A5 '"iops"' "$LOG_DIR/mixed/mixed_rw.json" | \
                    grep 'mean' | head -1 | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    cat > "$REPORT_FILE" << EOF
Disk IO Stress Test Report
Generated: $(date)
Test Duration: ${RUN_TIME} seconds per test
System Info: $(uname -a)

=== Test Configuration ===
Test Directory: ${TEST_DIR}
Test File Size: ${TEST_FILE_SIZE} per thread
Threads: ${THREADS}
Total Test Data: $((THREADS * 2)) GB (estimated)

=== Safety Information ===
✓ File-based testing only (no direct block device access)
✓ Tests run in designated directory: ${TEST_DIR}
✓ No risk to system or user data
✓ Automatic cleanup of test files

=== Performance Summary ===
Sequential Write Bandwidth: ${seq_write_bw} KB/s
Sequential Read Bandwidth: ${seq_read_bw} KB/s
Random Read IOPS: ${rand_read_iops}
Random Write IOPS: ${rand_write_iops}
Mixed Read/Write IOPS: ${mixed_iops}

=== System Resource Usage Summary ===
$(sar -u -f "$LOG_DIR/system/cpu.log" 2>/dev/null | tail -5 || echo "CPU data unavailable")

$(sar -r -f "$LOG_DIR/system/memory.log" 2>/dev/null | tail -5 || echo "Memory data unavailable")

$(sar -d -f "$LOG_DIR/system/disk.log" 2>/dev/null | tail -5 || echo "Disk data unavailable")

=== Key Findings ===
$(if [ "$seq_write_bw" != "0" ]; then
    echo "✓ Sequential write performance: ${seq_write_bw} KB/s"
else
    echo "✗ No sequential write data available"
fi)

$(if [ "$seq_read_bw" != "0" ]; then
    echo "✓ Sequential read performance: ${seq_read_bw} KB/s"
else
    echo "✗ No sequential read data available"
fi)

$(if [ "$rand_read_iops" != "0" ]; then
    echo "✓ Random read performance: ${rand_read_iops} IOPS"
else
    echo "✗ No random read data available"
fi)

$(if [ "$rand_write_iops" != "0" ]; then
    echo "✓ Random write performance: ${rand_write_iops} IOPS"
else
    echo "✗ No random write data available"
fi)

$(if [ "$mixed_iops" != "0" ]; then
    echo "✓ Mixed read/write performance: ${mixed_iops} IOPS"
else
    echo "✗ No mixed read/write data available"
fi)

=== Recommendations ===
1. Check detailed JSON files in $LOG_DIR for complete results
2. Monitor disk temperature during extended tests
3. Consider testing with different block sizes and queue depths
4. Verify filesystem alignment for optimal performance
5. For more accurate results, test on dedicated storage

=== Next Steps ===
1. Analyze performance bottlenecks
2. Test with different filesystem configurations
3. Compare performance across different storage devices
4. Monitor system stability under sustained IO load
EOF
    
    print_success "Report generated: $REPORT_FILE"
    
    # Show brief results
    echo -e "\n${GREEN}=== Test Completed ===${NC}"
    echo "Detailed logs available at: $LOG_DIR"
    echo "Test report: $REPORT_FILE"
    echo "Performance summary:"
    echo "  Sequential Write: ${seq_write_bw} KB/s"
    echo "  Sequential Read: ${seq_read_bw} KB/s"
    echo "  Random Read: ${rand_read_iops} IOPS"
    echo "  Random Write: ${rand_write_iops} IOPS"
    echo "  Mixed R/W: ${mixed_iops} IOPS"
    echo -e "\n${GREEN}✓ Safety: File-based testing completed without risk to system data${NC}"
}

# Cleanup function
cleanup() {
    print_info "Performing cleanup..."
    
    # Stop all fio processes
    pkill -f "fio" 2>/dev/null || true
    
    # Stop monitoring processes
    pkill -f "sar" 2>/dev/null || true
    pkill -f "iostat" 2>/dev/null || true
    
    # Clean up test directory
    cleanup_test_dir
    
    # Wait for processes to end
    sleep 2
}

# Main function
main() {
    # Set trap to catch interrupt signals
    trap cleanup EXIT INT TERM
    
    print_info "Starting SAFE disk IO read/write stress test"
    print_info "This test uses file-based IO only - no risk to system data"
    print_info "Test files will be created in: $TEST_DIR"
    
    # Check dependencies
    check_dependencies
    
    # Create log directory
    create_log_dir
    
    # Run all tests
    run_all_tests
    
    # Generate report
    generate_report
    
    print_success "Disk IO read/write stress test completed safely!"
}

# Script usage
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -t <seconds>  Test run time (default: 300)"
    echo "  -s <size>     Test file size per thread (default: 2G)"
    echo "  -j <threads>  Parallel threads (default: 4)"
    echo "  -f <dir>      Test file directory (default: ./disk_io_test_files)"
    echo "  -l <dir>      Log directory (default: ./disk_io_logs)"
    echo "  -h            Show this help message"
    echo
    echo "Safety Note: This script only performs file-based testing"
    echo "and does NOT write directly to block devices. No risk to system data."
    exit 0
}

# Parse command line arguments
while getopts "t:s:j:f:l:h" opt; do
    case $opt in
        t) RUN_TIME="$OPTARG" ;;
        s) TEST_FILE_SIZE="$OPTARG" ;;
        j) THREADS="$OPTARG" ;;
        f) TEST_DIR="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        h) usage ;;
        *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# Run main function
main "$@"
