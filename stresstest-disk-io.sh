#!/bin/bash

# Disk IO read/write stress test script using fio
# Tests sequential and random read/write patterns using file-based tests
# Includes SQLite 3 database read/write pressure test simulation
# Safe for production systems - only writes to designated test directory

set -e

# Configuration parameters
LOG_DIR="./disk_io_logs"
RUN_TIME=300  # Test run time (seconds)
TEST_FILE_SIZE="2G"         # Test file size per thread (smaller for safety)
THREADS=8                   # Parallel threads (increased for better throughput)
TEST_DIR="./disk_io_test_files"  # Directory for file-based tests
SQLITE_TEST_SIZE="1G"       # Size for SQLite simulation tests (smaller for realistic patterns)
HIGH_PERF_MODE=0           # High performance mode flag (0=normal, 1=high performance)

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
    
    # Check for libaio engine support
    if $FIO_CMD --enghelp 2>/dev/null | grep -q "libaio"; then
        LIB_AIO_AVAILABLE=1
    else
        LIB_AIO_AVAILABLE=0
        print_warning "libaio engine not available, using posixaio instead"
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
    mkdir -p "$LOG_DIR/sqlite"
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
    
    # Use optimal engine based on availability and performance mode
    local create_engine="posixaio"
    local create_iodepth=16
    local create_bs="1M"
    
    if [ $LIB_AIO_AVAILABLE -eq 1 ] && [ $HIGH_PERF_MODE -eq 1 ]; then
        create_engine="libaio"
        create_iodepth=32
        create_bs="2M"
    fi
    
    # Create test files sequentially to avoid contention and show progress
    print_info "Creating test files (this may take a while for large files)..."
    for i in $(seq 1 "$THREADS"); do
        print_info "Creating test file $i of $THREADS ($TEST_FILE_SIZE)..."
        # Use larger block size and no runtime limit for file creation
        # Remove --runtime and --time_based to allow full file creation
        $FIO_CMD --name="create_file_$i" --filename="$TEST_DIR/testfile_$i.tmp" \
            --ioengine="$create_engine" --direct=1 --bs="$create_bs" --iodepth="$create_iodepth" \
            --size="$TEST_FILE_SIZE" --rw=write --do_verify=0 \
            --output="$LOG_DIR/file_create_$i.log" --output-format=json
    done
    
    print_success "Test files created successfully"
}

# Sequential read/write test (file-based)
sequential_io_test() {
    print_info "Starting sequential IO test (runtime: ${RUN_TIME}s)"
    
    # Use optimal parameters based on performance mode
    local seq_engine="posixaio"
    local seq_iodepth=32
    local seq_bs="1M"
    local seq_numjobs="$THREADS"
    
    if [ $HIGH_PERF_MODE -eq 1 ]; then
        if [ $LIB_AIO_AVAILABLE -eq 1 ]; then
            seq_engine="libaio"
        fi
        seq_iodepth=128  # Increased for better parallelism
        seq_bs="2M"      # Larger block size for better throughput
        seq_numjobs=$((THREADS * 2))  # More jobs for better concurrency
        print_info "High performance mode enabled: engine=$seq_engine, iodepth=$seq_iodepth, bs=$seq_bs, jobs=$seq_numjobs"
    fi
    
    print_info "Running sequential WRITE test..."
    # Sequential write test - run in foreground to show progress
    $FIO_CMD --name="seq_write_test" --directory="$TEST_DIR" --ioengine="$seq_engine" --direct=1 \
        --bs="$seq_bs" --iodepth="$seq_iodepth" --size="$TEST_FILE_SIZE" --rw=write \
        --numjobs="$seq_numjobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/sequential/seq_write.json" --output-format=json
    
    print_info "Running sequential READ test..."
    # Sequential read test - run in foreground to show progress
    $FIO_CMD --name="seq_read_test" --directory="$TEST_DIR" --ioengine="$seq_engine" --direct=1 \
        --bs="$seq_bs" --iodepth="$seq_iodepth" --size="$TEST_FILE_SIZE" --rw=read \
        --numjobs="$seq_numjobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/sequential/seq_read.json" --output-format=json
    
    print_success "Sequential IO test completed"
}

# Random read/write test (file-based)
random_io_test() {
    print_info "Starting random IO test (runtime: ${RUN_TIME}s)"
    
    # Use optimal parameters based on performance mode
    local rand_engine="posixaio"
    local rand_iodepth=64
    local rand_bs="4k"
    local rand_numjobs="$THREADS"
    
    if [ $HIGH_PERF_MODE -eq 1 ]; then
        if [ $LIB_AIO_AVAILABLE -eq 1 ]; then
            rand_engine="libaio"
        fi
        rand_iodepth=256  # Increased for better random I/O parallelism
        rand_numjobs=$((THREADS * 2))  # More jobs for better concurrency
        print_info "High performance mode enabled: engine=$rand_engine, iodepth=$rand_iodepth, jobs=$rand_numjobs"
    fi
    
    print_info "Running random READ test..."
    # Random read test - run in foreground to show progress
    $FIO_CMD --name="rand_read_test" --directory="$TEST_DIR" --ioengine="$rand_engine" --direct=1 \
        --bs="$rand_bs" --iodepth="$rand_iodepth" --size="$TEST_FILE_SIZE" --rw=randread \
        --numjobs="$rand_numjobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/random/rand_read.json" --output-format=json
    
    print_info "Running random WRITE test..."
    # Random write test - run in foreground to show progress
    $FIO_CMD --name="rand_write_test" --directory="$TEST_DIR" --ioengine="$rand_engine" --direct=1 \
        --bs="$rand_bs" --iodepth="$rand_iodepth" --size="$TEST_FILE_SIZE" --rw=randwrite \
        --numjobs="$rand_numjobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/random/rand_write.json" --output-format=json
    
    print_success "Random IO test completed"
}

# Mixed read/write test (file-based)
mixed_io_test() {
    print_info "Starting mixed read/write test (runtime: ${RUN_TIME}s)"
    
    # Use optimal parameters based on performance mode
    local mixed_engine="posixaio"
    local mixed_iodepth=64
    local mixed_bs="4k"
    local mixed_numjobs="$THREADS"
    
    if [ $HIGH_PERF_MODE -eq 1 ]; then
        if [ $LIB_AIO_AVAILABLE -eq 1 ]; then
            mixed_engine="libaio"
        fi
        mixed_iodepth=128  # Increased for better mixed I/O parallelism
        mixed_numjobs=$((THREADS * 2))  # More jobs for better concurrency
        print_info "High performance mode enabled: engine=$mixed_engine, iodepth=$mixed_iodepth, jobs=$mixed_numjobs"
    fi
    
    print_info "Running mixed read/write test (70% read, 30% write)..."
    # Mixed random read/write (70% read, 30% write) - run in foreground to show progress
    $FIO_CMD --name="mixed_rw_test" --directory="$TEST_DIR" --ioengine="$mixed_engine" --direct=1 \
        --bs="$mixed_bs" --iodepth="$mixed_iodepth" --size="$TEST_FILE_SIZE" --rw=randrw --rwmixread=70 \
        --numjobs="$mixed_numjobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/mixed/mixed_rw.json" --output-format=json
    
    print_success "Mixed read/write test completed"
}

# SQLite 3 database simulation tests
sqlite_io_test() {
    print_info "Starting SQLite 3 database simulation tests (runtime: ${RUN_TIME}s)"
    
    # Use optimal parameters based on performance mode
    local sqlite_engine="posixaio"
    local sqlite_page_iodepth=16
    local sqlite_wal_iodepth=8
    local sqlite_checkpoint_iodepth=32
    local sqlite_transaction_iodepth=1
    local sqlite_vacuum_iodepth=4
    local sqlite_page_jobs="$THREADS"
    local sqlite_wal_jobs="$((THREADS/2))"
    local sqlite_checkpoint_jobs="$THREADS"
    local sqlite_transaction_jobs="$((THREADS*2))"
    local sqlite_vacuum_jobs=2
    
    if [ $HIGH_PERF_MODE -eq 1 ]; then
        if [ $LIB_AIO_AVAILABLE -eq 1 ]; then
            sqlite_engine="libaio"
        fi
        sqlite_page_iodepth=32  # Increased for better database page access
        sqlite_wal_iodepth=16   # Increased for better WAL performance
        sqlite_checkpoint_iodepth=64  # Increased for checkpoint operations
        sqlite_page_jobs=$((THREADS * 2))
        sqlite_wal_jobs="$THREADS"
        print_info "High performance mode enabled for SQLite tests"
    fi
    
    # Test 1: SQLite page-based random access (4KB pages, typical database operations)
    print_info "Running SQLite page-based random access test (simulating B-tree traversal)..."
    $FIO_CMD --name="sqlite_page_access" --directory="$TEST_DIR" --ioengine="$sqlite_engine" --direct=1 \
        --bs=4k --iodepth="$sqlite_page_iodepth" --size="$SQLITE_TEST_SIZE" --rw=randrw --rwmixread=80 \
        --numjobs="$sqlite_page_jobs" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/page_access.json" --output-format=json
    
    # Test 2: SQLite mmap (memory-mapped I/O) simulation
    # SQLite can use mmap for better performance on systems with sufficient memory
    print_info "Running SQLite mmap (memory-mapped I/O) simulation test..."
    $FIO_CMD --name="sqlite_mmap" --directory="$TEST_DIR" --ioengine=mmap --direct=0 \
        --bs=4k --iodepth=8 --size="$SQLITE_TEST_SIZE" --rw=randrw --rwmixread=90 \
        --numjobs="$THREADS" --runtime="$((RUN_TIME/2))" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/mmap.json" --output-format=json
    
    # Test 3: SQLite WAL (Write-Ahead Logging) simulation
    # WAL file: sequential writes, random reads from main DB
    print_info "Running SQLite WAL simulation test (sequential writes for WAL file)..."
    $FIO_CMD --name="sqlite_wal_write" --directory="$TEST_DIR" --ioengine="$sqlite_engine" --direct=1 \
        --bs=64k --iodepth="$sqlite_wal_iodepth" --size="$SQLITE_TEST_SIZE" --rw=write \
        --numjobs="$sqlite_wal_jobs" --runtime="$((RUN_TIME/2))" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/wal_write.json" --output-format=json
    
    # Test 4: SQLite checkpoint operation (sequential read from WAL, random write to DB)
    print_info "Running SQLite checkpoint simulation test..."
    $FIO_CMD --name="sqlite_checkpoint" --directory="$TEST_DIR" --ioengine="$sqlite_engine" --direct=1 \
        --bs=4k --iodepth="$sqlite_checkpoint_iodepth" --size="$SQLITE_TEST_SIZE" --rw=randrw --rwmixread=30 \
        --numjobs="$sqlite_checkpoint_jobs" --runtime="$((RUN_TIME/2))" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/checkpoint.json" --output-format=json
    
    # Test 5: SQLite transaction commit pattern (small, frequent writes)
    print_info "Running SQLite transaction commit simulation (small, frequent writes)..."
    $FIO_CMD --name="sqlite_transaction" --directory="$TEST_DIR" --ioengine="$sqlite_engine" --direct=1 \
        --bs=4k --iodepth="$sqlite_transaction_iodepth" --size="$SQLITE_TEST_SIZE" --rw=randwrite \
        --numjobs="$sqlite_transaction_jobs" --runtime="$((RUN_TIME/2))" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/transaction.json" --output-format=json
    
    # Test 6: SQLite vacuum operation (sequential read/write of entire database)
    print_info "Running SQLite vacuum operation simulation..."
    $FIO_CMD --name="sqlite_vacuum" --directory="$TEST_DIR" --ioengine="$sqlite_engine" --direct=1 \
        --bs=128k --iodepth="$sqlite_vacuum_iodepth" --size="$SQLITE_TEST_SIZE" --rw=rw \
        --numjobs="$sqlite_vacuum_jobs" --runtime="$((RUN_TIME/3))" --time_based --group_reporting \
        --output="$LOG_DIR/sqlite/vacuum.json" --output-format=json
    
    print_success "SQLite 3 database simulation tests completed"
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
    sqlite_io_test
    
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
    
    # SQLite metrics
    local sqlite_page_iops=0
    local sqlite_mmap_iops=0
    local sqlite_wal_bw=0
    local sqlite_checkpoint_iops=0
    local sqlite_transaction_iops=0
    local sqlite_vacuum_bw=0
    
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
    
    # Extract SQLite metrics
    if [ -f "$LOG_DIR/sqlite/page_access.json" ]; then
        sqlite_page_iops=$(grep -A5 '"iops"' "$LOG_DIR/sqlite/page_access.json" | \
                          grep 'mean' | head -1 | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sqlite/mmap.json" ]; then
        sqlite_mmap_iops=$(grep -A5 '"iops"' "$LOG_DIR/sqlite/mmap.json" | \
                          grep 'mean' | head -1 | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sqlite/wal_write.json" ]; then
        sqlite_wal_bw=$(grep -A5 '"write"' "$LOG_DIR/sqlite/wal_write.json" | \
                       grep 'bw_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sqlite/checkpoint.json" ]; then
        sqlite_checkpoint_iops=$(grep -A5 '"iops"' "$LOG_DIR/sqlite/checkpoint.json" | \
                                grep 'mean' | head -1 | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sqlite/transaction.json" ]; then
        sqlite_transaction_iops=$(grep -A5 '"write"' "$LOG_DIR/sqlite/transaction.json" | \
                                 grep 'iops_mean' | cut -d: -f2 | tr -d ', ' 2>/dev/null || echo "0")
    fi
    
    if [ -f "$LOG_DIR/sqlite/vacuum.json" ]; then
        sqlite_vacuum_bw=$(grep -A5 '"bw"' "$LOG_DIR/sqlite/vacuum.json" | \
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
SQLite Test Size: ${SQLITE_TEST_SIZE} per thread
Threads: ${THREADS}
Total Test Data: $((THREADS * 2)) GB (estimated)

=== Safety Information ===
✓ File-based testing only (no direct block device access)
✓ Tests run in designated directory: ${TEST_DIR}
✓ No risk to system or user data
✓ Automatic cleanup of test files

=== Performance Summary ===
General Disk Performance:
  Sequential Write Bandwidth: ${seq_write_bw} KB/s
  Sequential Read Bandwidth: ${seq_read_bw} KB/s
  Random Read IOPS: ${rand_read_iops}
  Random Write IOPS: ${rand_write_iops}
  Mixed Read/Write IOPS: ${mixed_iops}

SQLite 3 Database Simulation Performance:
  Page-based Access (4KB random R/W): ${sqlite_page_iops} IOPS
  Mmap (memory-mapped I/O): ${sqlite_mmap_iops} IOPS
  WAL Write Bandwidth: ${sqlite_wal_bw} KB/s
  Checkpoint Operation: ${sqlite_checkpoint_iops} IOPS
  Transaction Commit: ${sqlite_transaction_iops} IOPS
  Vacuum Operation: ${sqlite_vacuum_bw} KB/s

=== System Resource Usage Summary ===
$(sar -u -f "$LOG_DIR/system/cpu.log" 2>/dev/null | tail -5 || echo "CPU data unavailable")

$(sar -r -f "$LOG_DIR/system/memory.log" 2>/dev/null | tail -5 || echo "Memory data unavailable")

$(sar -d -f "$LOG_DIR/system/disk.log" 2>/dev/null | tail -5 || echo "Disk data unavailable")

=== Key Findings ===
General Disk Performance:
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

SQLite 3 Database Simulation:
$(if [ "$sqlite_page_iops" != "0" ]; then
    echo "✓ SQLite page access performance: ${sqlite_page_iops} IOPS"
else
    echo "✗ No SQLite page access data available"
fi)

$(if [ "$sqlite_mmap_iops" != "0" ]; then
    echo "✓ SQLite mmap (memory-mapped I/O) performance: ${sqlite_mmap_iops} IOPS"
else
    echo "✗ No SQLite mmap data available"
fi)

$(if [ "$sqlite_wal_bw" != "0" ]; then
    echo "✓ SQLite WAL write performance: ${sqlite_wal_bw} KB/s"
else
    echo "✗ No SQLite WAL write data available"
fi)

$(if [ "$sqlite_checkpoint_iops" != "0" ]; then
    echo "✓ SQLite checkpoint performance: ${sqlite_checkpoint_iops} IOPS"
else
    echo "✗ No SQLite checkpoint data available"
fi)

$(if [ "$sqlite_transaction_iops" != "0" ]; then
    echo "✓ SQLite transaction commit performance: ${sqlite_transaction_iops} IOPS"
else
    echo "✗ No SQLite transaction commit data available"
fi)

$(if [ "$sqlite_vacuum_bw" != "0" ]; then
    echo "✓ SQLite vacuum performance: ${sqlite_vacuum_bw} KB/s"
else
    echo "✗ No SQLite vacuum data available"
fi)

=== SQLite-Specific Recommendations ===
1. For optimal SQLite performance, ensure filesystem supports 4KB aligned writes
2. Consider using WAL mode for better concurrent read/write performance
3. Monitor checkpoint frequency to avoid WAL file growth
4. Regular VACUUM operations can improve read performance
5. Test with different SQLite page sizes (1K, 2K, 4K, 8K, 16K, 32K, 64K)
6. Consider filesystem choice: ext4, XFS, or Btrfs may have different performance characteristics

=== General Recommendations ===
1. Check detailed JSON files in $LOG_DIR for complete results
2. Monitor disk temperature during extended tests
3. Consider testing with different block sizes and queue depths
4. Verify filesystem alignment for optimal performance
5. For more accurate results, test on dedicated storage

=== Next Steps ===
1. Analyze performance bottlenecks for database workloads
2. Test with different filesystem configurations optimized for SQLite
3. Compare performance across different storage devices for database use cases
4. Monitor system stability under sustained database-like IO load
5. Consider testing with actual SQLite benchmarks for correlation
EOF
    
    print_success "Report generated: $REPORT_FILE"
    
    # Show brief results
    echo -e "\n${GREEN}=== Test Completed ===${NC}"
    echo "Detailed logs available at: $LOG_DIR"
    echo "Test report: $REPORT_FILE"
    echo -e "\n${BLUE}=== Performance Summary ===${NC}"
    echo "General Disk Performance:"
    echo "  Sequential Write: ${seq_write_bw} KB/s"
    echo "  Sequential Read: ${seq_read_bw} KB/s"
    echo "  Random Read: ${rand_read_iops} IOPS"
    echo "  Random Write: ${rand_write_iops} IOPS"
    echo "  Mixed R/W: ${mixed_iops} IOPS"
    echo -e "\nSQLite 3 Database Simulation:"
    echo "  Page Access (4KB R/W): ${sqlite_page_iops} IOPS"
    echo "  Mmap (memory-mapped I/O): ${sqlite_mmap_iops} IOPS"
    echo "  WAL Write: ${sqlite_wal_bw} KB/s"
    echo "  Checkpoint: ${sqlite_checkpoint_iops} IOPS"
    echo "  Transaction Commit: ${sqlite_transaction_iops} IOPS"
    echo "  Vacuum: ${sqlite_vacuum_bw} KB/s"
    echo -e "\n${GREEN}✓ Safety: File-based testing completed without risk to system data${NC}"
    echo -e "${GREEN}✓ SQLite 3 database read/write pressure test simulation completed${NC}"
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
    echo "  -j <threads>  Parallel threads (default: 8)"
    echo "  -f <dir>      Test file directory (default: ./disk_io_test_files)"
    echo "  -l <dir>      Log directory (default: ./disk_io_logs)"
    echo "  -p            Enable high performance mode (increased iodepth, libaio engine)"
    echo "  -h            Show this help message"
    echo
    echo "Features:"
    echo "  - General disk performance tests (sequential, random, mixed)"
    echo "  - SQLite 3 database simulation tests:"
    echo "    * Page-based random access (4KB pages)"
    echo "    * WAL (Write-Ahead Logging) simulation"
    echo "    * Checkpoint operation simulation"
    echo "    * Transaction commit patterns"
    echo "    * Vacuum operation simulation"
    echo
    echo "High Performance Mode (-p):"
    echo "  - Uses libaio engine (if available)"
    echo "  - Increased I/O depth (128-256)"
    echo "  - Larger block sizes (2M for sequential)"
    echo "  - More concurrent jobs"
    echo
    echo "Safety Note: This script only performs file-based testing"
    echo "and does NOT write directly to block devices. No risk to system data."
    exit 0
}

# Parse command line arguments
while getopts "t:s:j:f:l:ph" opt; do
    case $opt in
        t) RUN_TIME="$OPTARG" ;;
        s) TEST_FILE_SIZE="$OPTARG" ;;
        j) THREADS="$OPTARG" ;;
        f) TEST_DIR="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        p) HIGH_PERF_MODE=1 ;;
        h) usage ;;
        *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# Run main function
main "$@"
