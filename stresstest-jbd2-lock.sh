#!/bin/bash

# JBD2 lock contention stress test script
# Scenario simulation: stress-ng consumes memory → kswapd continuously awakened + huge create/unlink → dentry/icache explosion
# kswapd calls prune_icache_sb() → ext4_evict_inode() → acquires journal->j_checkpoint_mutex
# Meanwhile stress-ng's io threads keep writing files → jbd2 transaction commit thread also competes for same mutex
# NVMe drive too fast → jbd2 commit completes quickly but holds mutex until transaction checkpoint ends
# Causes kswapd to wait 120s for lock, kernel prints task kswapd0:1420 blocked … jbd2_log_wait_commit … stack trace

set -e

# Configuration parameters
LOG_DIR="./jbd2_lock_logs"
RUN_TIME=600  # Test run time (seconds), needs longer time to trigger lock contention
TEST_DIR="./jbd2_test_files"  # Test file directory
MEMORY_SIZE="4G"            # Memory test size (occupies about 50% memory)
FILE_COUNT=100000           # Number of files to create/delete
IO_THREADS=8                # IO thread count
MEMORY_THREADS=4            # Memory pressure thread count

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
    if command -v stress-ng &> /dev/null; then
        STRESS_NG_CMD="stress-ng"
    elif [ -x "./stress-ng" ]; then
        STRESS_NG_CMD="./stress-ng"
    else
        missing+=("stress-ng")
    fi

    if command -v fio &> /dev/null; then
        FIO_CMD="fio"
    elif [ -x "./fio" ]; then
        FIO_CMD="./fio"
    else
        missing+=("fio")
    fi
    
    if ! command -v dmesg &> /dev/null; then
        missing+=("dmesg")
    fi
    
    if ! command -v sar &> /dev/null; then
        missing+=("sysstat")
    fi
    
    if ! command -v vmstat &> /dev/null; then
        print_warning "vmstat command not found, memory monitoring may be limited"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        echo "Please install:"
        echo "  Ubuntu/Debian: sudo apt-get install stress-ng fio sysstat"
        echo "  RHEL/CentOS: sudo yum install stress-ng fio sysstat"
        exit 1
    fi
}

# Create log directory
create_log_dir() {
    mkdir -p "$LOG_DIR"
    mkdir -p "$LOG_DIR/system"
    mkdir -p "$LOG_DIR/kernel"
    mkdir -p "$TEST_DIR"
}

# Clean up test directory
cleanup_test_dir() {
    if [ -d "$TEST_DIR" ]; then
        print_info "Cleaning test directory: $TEST_DIR"
        # Use find to avoid "Argument list too long" error
        # First delete all .tmp files
        find "$TEST_DIR" -type f -name "*.tmp" -delete 2>/dev/null || true
        # Then delete any remaining files and directories
        find "$TEST_DIR" -mindepth 1 -delete 2>/dev/null || true
    fi
}

# System monitoring (run in background)
start_monitoring() {
    print_info "Starting system monitoring..."
    
    # Record initial kernel messages
    dmesg -c > "$LOG_DIR/kernel/dmesg_initial.log" 2>/dev/null || true
    
    # CPU, memory, IO monitoring
    sar -u 1 > "$LOG_DIR/system/cpu.log" 2>&1 &
    SAR_CPU_PID=$!
    
    sar -r 1 > "$LOG_DIR/system/memory.log" 2>&1 &
    SAR_MEM_PID=$!
    
    sar -d 1 > "$LOG_DIR/system/disk.log" 2>&1 &
    SAR_DISK_PID=$!
    
    # Monitor kernel messages for lock contention
    dmesg -w > "$LOG_DIR/kernel/dmesg_live.log" 2>&1 &
    DMESG_PID=$!
    
    # Monitor process status
    ps aux --sort=-%mem > "$LOG_DIR/system/processes_initial.log" 2>&1
}

# Stop monitoring
stop_monitoring() {
    print_info "Stopping system monitoring..."
    kill $SAR_CPU_PID $SAR_MEM_PID $SAR_DISK_PID $DMESG_PID 2>/dev/null || true
    sleep 2
}

# Memory pressure test (trigger kswapd)
memory_stress_test() {
    print_info "Starting memory pressure test (trigger kswapd)..."
    print_info "Memory usage target: $MEMORY_SIZE, thread count: $MEMORY_THREADS"
    
    # Use stress-ng to consume memory, trigger kswapd
    # --vm-keep: keep memory allocated without releasing
    # --vm-hang: pause time after memory operations, set to 0 for continuous pressure
    $STRESS_NG_CMD --vm "$MEMORY_THREADS" --vm-bytes "$MEMORY_SIZE" --vm-method all \
        --vm-hang 0 --timeout "${RUN_TIME}s" --metrics-brief \
        > "$LOG_DIR/memory_stress.log" 2>&1 &
    STRESS_NG_PID=$!
    
    echo $STRESS_NG_PID > "$LOG_DIR/stress_ng.pid"
    print_success "Memory pressure test started (PID: $STRESS_NG_PID)"
}

# File create/delete operations (trigger dentry/icache growth)
file_operations_test() {
    print_info "Starting file create/delete operations (trigger dentry/icache growth)..."
    print_info "Target file count: $FILE_COUNT, test directory: $TEST_DIR"
    
    local script_file="$LOG_DIR/file_ops.sh"
    
    # Create file operations script
    cat > "$script_file" << 'EOF'
#!/bin/bash
TEST_DIR="$1"
FILE_COUNT="$2"
LOG_FILE="$3"

echo "Starting file create/delete loop..." >> "$LOG_FILE"

while true; do
    # Create many small files
    for i in $(seq 1 $FILE_COUNT); do
        echo "test data $i" > "$TEST_DIR/file_$i.tmp" 2>/dev/null
        # Delete some files after creating 100
        if [ $((i % 100)) -eq 0 ]; then
            rm -f "$TEST_DIR/file_$((i-99)).tmp" 2>/dev/null
        fi
    done
    
    # Clean up remaining files
    rm -f "$TEST_DIR/*.tmp" 2>/dev/null
    
    echo "Completed one file create/delete cycle" >> "$LOG_FILE"
done
EOF
    
    chmod +x "$script_file"
    
    # Run file operations
    "$script_file" "$TEST_DIR" "$FILE_COUNT" "$LOG_DIR/file_operations.log" &
    FILE_OPS_PID=$!
    
    echo $FILE_OPS_PID > "$LOG_DIR/file_ops.pid"
    print_success "File operations test started (PID: $FILE_OPS_PID)"
}

# Continuous file writing (trigger jbd2 transactions and potential IO errors)
continuous_io_test() {
    print_info "Starting aggressive continuous file writing (trigger jbd2 transactions and IO errors)..."
    print_info "IO thread count: $IO_THREADS"
    
    # Use fio for aggressive random writes to trigger potential IO errors
    # More aggressive parameters to increase chance of blk_update_request: IO error
    $FIO_CMD --name=jbd2_io_test --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=512 --iodepth=256 --size=2G --rw=randwrite \
        --numjobs="$((IO_THREADS * 2))" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/fio_io.log" --output-format=json &
    FIO_PID=$!
    
    # Additional aggressive write test with verify to trigger read errors
    $FIO_CMD --name=jbd2_verify_test --directory="$TEST_DIR" --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=128 --size=1G --rw=randrw --rwmixread=50 --verify=crc32c \
        --numjobs="$IO_THREADS" --runtime="$RUN_TIME" --time_based --group_reporting \
        --output="$LOG_DIR/fio_verify.log" --output-format=json &
    FIO_VERIFY_PID=$!
    
    echo $FIO_PID > "$LOG_DIR/fio.pid"
    echo $FIO_VERIFY_PID > "$LOG_DIR/fio_verify.pid"
    print_success "Aggressive continuous IO tests started (PIDs: $FIO_PID, $FIO_VERIFY_PID)"
}

# Monitor lock contention and IO errors
monitor_lock_contention() {
    print_info "Starting JBD2 lock contention and IO error monitoring..."
    
    local monitor_script="$LOG_DIR/monitor_lock.sh"
    
    cat > "$monitor_script" << 'EOF'
#!/bin/bash
LOG_DIR="$1"
RUN_TIME="$2"

echo "Starting lock contention and IO error monitoring..." > "$LOG_DIR/lock_monitor.log"

# Monitoring counters
lock_detected=0
kswapd_blocked=0
jbd2_wait=0
io_errors=0
blk_update_errors=0

for i in $(seq 1 $RUN_TIME); do
    # Check dmesg for lock contention signs
    if dmesg | tail -100 | grep -q "blocked.*jbd2_log_wait_commit"; then
        echo "[$(date)] Detected jbd2_log_wait_commit blocking" >> "$LOG_DIR/lock_detections.log"
        ((lock_detected++))
    fi
    
    if dmesg | tail -100 | grep -q "task kswapd.*blocked"; then
        echo "[$(date)] Detected kswapd blocking" >> "$LOG_DIR/kswapd_blocked.log"
        ((kswapd_blocked++))
    fi
    
    if dmesg | tail -100 | grep -q "jbd2.*checkpoint"; then
        echo "[$(date)] Detected jbd2 checkpoint activity" >> "$LOG_DIR/jbd2_activity.log"
        ((jbd2_wait++))
    fi
    
    # Check for IO errors - specifically blk_update_request: IO error
    if dmesg | tail -100 | grep -q "blk_update_request.*IO error"; then
        echo "[$(date)] Detected blk_update_request: IO error" >> "$LOG_DIR/io_errors.log"
        dmesg | tail -100 | grep "blk_update_request.*IO error" >> "$LOG_DIR/io_errors_detailed.log"
        ((blk_update_errors++))
    fi
    
    # Check for general IO errors
    if dmesg | tail -100 | grep -qi "IO error\|I/O error\|read error\|write error"; then
        echo "[$(date)] Detected general IO error" >> "$LOG_DIR/io_errors.log"
        ((io_errors++))
    fi
    
    # Check process status
    if ps aux | grep -q "[k]swapd0"; then
        echo "[$(date)] kswapd0 process status:" >> "$LOG_DIR/kswapd_status.log"
        ps aux | grep "[k]swapd0" >> "$LOG_DIR/kswapd_status.log"
    fi
    
    # Check memory pressure
    if [ -f /proc/vmstat ]; then
        grep -E "(pgscan|pgsteal|allocstall)" /proc/vmstat >> "$LOG_DIR/vmstat.log"
    fi
    
    # Check disk stats for errors
    if [ -f /proc/diskstats ]; then
        cat /proc/diskstats >> "$LOG_DIR/diskstats.log"
    fi
    
    sleep 1
    
    # Report every 30 seconds (more frequent for debugging)
    if [ $((i % 30)) -eq 0 ]; then
        echo "[$(date)] Monitoring progress: $i/$RUN_TIME seconds" >> "$LOG_DIR/lock_monitor.log"
        echo "[$(date)] Lock contention detections: $lock_detected times" >> "$LOG_DIR/lock_monitor.log"
        echo "[$(date)] kswapd blocking: $kswapd_blocked times" >> "$LOG_DIR/lock_monitor.log"
        echo "[$(date)] jbd2 activity: $jbd2_wait times" >> "$LOG_DIR/lock_monitor.log"
        echo "[$(date)] blk_update_request IO errors: $blk_update_errors times" >> "$LOG_DIR/lock_monitor.log"
        echo "[$(date)] General IO errors: $io_errors times" >> "$LOG_DIR/lock_monitor.log"
        
        # Also print to console for immediate feedback (use stderr to avoid mixing with fio stdout)
        echo "[$(date)] Progress: $i/$RUN_TIME s, IO errors: $blk_update_errors" >&2
    fi
done

echo "Monitoring completed" >> "$LOG_DIR/lock_monitor.log"
echo "Total blk_update_request IO errors detected: $blk_update_errors" >> "$LOG_DIR/lock_monitor.log"
echo "Total general IO errors detected: $io_errors" >> "$LOG_DIR/lock_monitor.log"
EOF
    
    chmod +x "$monitor_script"
    
    # Run monitoring
    "$monitor_script" "$LOG_DIR" "$RUN_TIME" &
    MONITOR_PID=$!
    
    echo $MONITOR_PID > "$LOG_DIR/monitor.pid"
    print_success "Lock contention and IO error monitoring started (PID: $MONITOR_PID)"
}

# Setup device-mapper error device to simulate IO errors
setup_error_device() {
    print_info "Setting up device-mapper error device to simulate IO errors..."
    
    # Check if we have permission to use dmsetup
    if ! command -v dmsetup &> /dev/null; then
        print_warning "dmsetup not found, skipping error device setup"
        return 1
    fi
    
    # Check if we're running as root (dmsetup typically requires root)
    if [ "$EUID" -ne 0 ]; then
        print_warning "Not running as root, device-mapper error injection may not work"
        print_warning "Try running with sudo or as root for guaranteed error injection"
    fi
    
    # Create a loop device as backing store if needed
    local backing_file="$LOG_DIR/error_device_backing.img"
    local loop_device=""
    
    # Create a 1GB backing file
    dd if=/dev/zero of="$backing_file" bs=1M count=1024 status=none 2>/dev/null || {
        print_warning "Failed to create backing file, using existing block device"
        # Try to find an existing block device we can use
        local test_dev="/dev/loop0"
        if [ -b "$test_dev" ]; then
            loop_device="$test_dev"
        else
            print_error "No suitable backing device found for error injection"
            return 1
        fi
    }
    
    if [ -z "$loop_device" ] && [ -f "$backing_file" ]; then
        # Setup loop device - improved logic to find truly free loop device
        print_info "Looking for free loop device..."
        
        # First try losetup -f to find next free device
        loop_device=$(losetup -f 2>/dev/null)
        if [ -n "$loop_device" ]; then
            # Check if the device is actually free (not in losetup -a)
            if losetup -a | grep -q "^$loop_device:"; then
                print_warning "Device $loop_device returned by 'losetup -f' is already in use"
                loop_device=""
            fi
        fi
        
        # If losetup -f didn't work or returned occupied device, try known free devices
        if [ -z "$loop_device" ]; then
            print_info "Trying known free loop devices..."
            for dev in /dev/loop12 /dev/loop16 /dev/loop17 /dev/loop18 /dev/loop19 /dev/loop20; do
                if [ -b "$dev" ] && ! losetup -a | grep -q "^$dev:"; then
                    loop_device="$dev"
                    print_info "Found free loop device: $loop_device"
                    break
                fi
            done
        fi
        
        # If still no free device, try to find any free loop device
        if [ -z "$loop_device" ]; then
            print_info "Scanning for any free loop device..."
            for i in {0..31}; do
                dev="/dev/loop$i"
                if [ -b "$dev" ] && ! losetup -a | grep -q "^$dev:"; then
                    loop_device="$dev"
                    print_info "Found free loop device: $loop_device"
                    break
                fi
            done
        fi
        
        # If we found a free loop device, try to set it up
        if [ -n "$loop_device" ]; then
            print_info "Setting up loop device $loop_device with backing file $backing_file"
            if losetup "$loop_device" "$backing_file" 2>/dev/null; then
                print_success "Successfully set up loop device $loop_device"
            else
                print_warning "Failed to setup loop device $loop_device, trying with sudo..."
                if sudo losetup "$loop_device" "$backing_file" 2>/dev/null; then
                    print_success "Successfully set up loop device $loop_device with sudo"
                else
                    print_error "Failed to setup loop device $loop_device even with sudo"
                    print_info "Trying to find already set up loop device..."
                    # Try to use an existing loop device that's already set up
                    loop_device=$(losetup -a | head -1 | cut -d: -f1)
                    if [ -z "$loop_device" ]; then
                        print_error "No loop device available for error injection"
                        return 1
                    else
                        print_warning "Using already set up loop device: $loop_device"
                    fi
                fi
            fi
        else
            print_error "No free loop device found for error injection"
            print_info "All loop devices 0-31 are occupied. Consider freeing some loop devices."
            return 1
        fi
    fi
    
    # Create device-mapper error device
    local error_device_name="jbd2_error_dev"
    local sector_size=512
    local total_sectors=2097152  # 1GB in 512-byte sectors
    
    # Remove existing device if present
    dmsetup remove "$error_device_name" 2>/dev/null || true
    
    # Create device-mapper table:
    # - First 1000 sectors: normal linear mapping
    # - Next 100 sectors: error target (returns I/O error)
    # - Rest: normal linear mapping
    cat > "$LOG_DIR/dm_table.txt" << EOF
0 1000 linear $loop_device 0
1000 100 error
1100 $((total_sectors - 1100)) linear $loop_device 1100
EOF
    
    # Create the device
    dmsetup create "$error_device_name" < "$LOG_DIR/dm_table.txt" 2>/dev/null || {
        print_error "Failed to create device-mapper error device"
        print_info "This may require root privileges. Trying with sudo..."
        
        # Try with sudo
        sudo dmsetup create "$error_device_name" < "$LOG_DIR/dm_table.txt" 2>/dev/null || {
            print_error "Failed to create error device even with sudo"
            print_info "Manual error device creation required for guaranteed IO errors"
            return 1
        }
    }
    
    ERROR_DEVICE="/dev/mapper/$error_device_name"
    export ERROR_DEVICE
    
    # Create test directory on error device
    local error_test_dir="$TEST_DIR/error_device"
    mkdir -p "$error_test_dir"
    
    # Try to mount if we have a filesystem (optional)
    if [ -b "$ERROR_DEVICE" ]; then
        # Create filesystem
        mkfs.ext4 -F "$ERROR_DEVICE" >/dev/null 2>&1 && {
            mount "$ERROR_DEVICE" "$error_test_dir" 2>/dev/null && {
                print_success "Error device mounted at $error_test_dir"
                ERROR_DEVICE_MOUNTED=true
                export ERROR_DEVICE_MOUNTED
                export ERROR_TEST_DIR="$error_test_dir"
            } || print_warning "Could not mount error device, using as raw block device"
        } || print_warning "Could not create filesystem on error device, using as raw block device"
    fi
    
    print_success "Device-mapper error device created: $ERROR_DEVICE"
    print_info "Sectors 1000-1099 will return I/O errors (guaranteeing blk_update_request messages)"
    
    # Save device info for cleanup
    echo "$error_device_name" > "$LOG_DIR/error_device_name.txt"
    [ -n "$loop_device" ] && echo "$loop_device" > "$LOG_DIR/loop_device.txt"
    [ -f "$backing_file" ] && echo "$backing_file" > "$LOG_DIR/backing_file.txt"
    
    return 0
}

# Cleanup error device
cleanup_error_device() {
    print_info "Cleaning up device-mapper error device..."
    
    local error_device_name=""
    local loop_device=""
    local backing_file=""
    
    [ -f "$LOG_DIR/error_device_name.txt" ] && error_device_name=$(cat "$LOG_DIR/error_device_name.txt")
    [ -f "$LOG_DIR/loop_device.txt" ] && loop_device=$(cat "$LOG_DIR/loop_device.txt")
    [ -f "$LOG_DIR/backing_file.txt" ] && backing_file=$(cat "$LOG_DIR/backing_file.txt")
    
    # Unmount if mounted
    if [ "${ERROR_DEVICE_MOUNTED:-false}" = "true" ] && [ -n "${ERROR_TEST_DIR:-}" ]; then
        umount "${ERROR_TEST_DIR}" 2>/dev/null || true
        rmdir "${ERROR_TEST_DIR}" 2>/dev/null || true
    fi
    
    # Remove device-mapper device
    if [ -n "$error_device_name" ]; then
        dmsetup remove "$error_device_name" 2>/dev/null || \
        sudo dmsetup remove "$error_device_name" 2>/dev/null || true
    fi
    
    # Remove loop device
    if [ -n "$loop_device" ] && [ -b "$loop_device" ]; then
        losetup -d "$loop_device" 2>/dev/null || true
    fi
    
    # Remove backing file
    if [ -n "$backing_file" ] && [ -f "$backing_file" ]; then
        rm -f "$backing_file" 2>/dev/null || true
    fi
    
    # Clean up temp files
    rm -f "$LOG_DIR/dm_table.txt" "$LOG_DIR/error_device_name.txt" \
          "$LOG_DIR/loop_device.txt" "$LOG_DIR/backing_file.txt" 2>/dev/null || true
    
    print_success "Error device cleanup completed"
}

# Run IO test on error device
run_error_device_io_test() {
    print_info "Starting IO test on error device to trigger guaranteed blk_update_request errors..."
    
    if [ -z "${ERROR_TEST_DIR:-}" ]; then
        print_warning "Error test directory not set, skipping error device IO test"
        return 1
    fi
    
    # Create a test file that spans the error sectors
    # The error sectors are at 1000-1099 (512-byte sectors)
    # That's 51200-56319 bytes offset
    # We'll create a 1MB file to ensure we hit error sectors
    
    local test_file="${ERROR_TEST_DIR}/error_test_file"
    
    # Write test pattern to file
    dd if=/dev/urandom of="$test_file" bs=1M count=10 2>/dev/null || {
        print_warning "Failed to create test file on error device"
        return 1
    }
    
    # Run fio test specifically targeting the error sectors
    # Use direct IO to bypass cache and ensure we hit the device
    $FIO_CMD --name=error_device_test --filename="$test_file" --ioengine=posixaio --direct=1 \
        --bs=4k --iodepth=16 --size=10M --offset=50000 --rw=randrw --rwmixread=50 \
        --numjobs=4 --runtime="$((RUN_TIME / 2))" --time_based --group_reporting \
        --output="$LOG_DIR/error_device_fio.log" --output-format=json &
    ERROR_FIO_PID=$!
    
    echo $ERROR_FIO_PID > "$LOG_DIR/error_fio.pid"
    print_success "Error device IO test started (PID: $ERROR_FIO_PID)"
    print_info "This test specifically targets sectors 1000-1099 which are configured to return I/O errors"
    print_info "This should guarantee blk_update_request: IO error messages in dmesg"
    
    return 0
}

# Run all tests in parallel
run_all_tests_parallel() {
    print_info "Starting JBD2 lock contention stress test..."
    print_info "Test duration: ${RUN_TIME} seconds"
    print_info "Log directory: ${LOG_DIR}"
    print_info "Test file directory: ${TEST_DIR}"
    
    # Clean up old test files
    cleanup_test_dir
    
    # Setup device-mapper error device for guaranteed IO errors
    local error_device_available=false
    setup_error_device && error_device_available=true
    
    # Start system monitoring
    start_monitoring
    
    # Run tests in parallel
    memory_stress_test
    sleep 5  # Give memory pressure test some time to start
    
    file_operations_test
    sleep 2
    
    # Run continuous IO test, using error device if available
    if [ "$error_device_available" = "true" ] && [ -n "${ERROR_TEST_DIR:-}" ]; then
        print_info "Using error device for IO tests at ${ERROR_TEST_DIR}"
        # Run additional test specifically on error device
        run_error_device_io_test
    fi
    
    continuous_io_test
    sleep 2
    
    monitor_lock_contention
    
    # Show progress
    print_info "All tests started, waiting for completion..."
    for i in $(seq 1 "$RUN_TIME"); do
        echo -ne "Test progress: $i/${RUN_TIME} seconds\r"
        
        # Check key processes every 30 seconds
        if [ $((i % 30)) -eq 0 ]; then
            if ! kill -0 $STRESS_NG_PID 2>/dev/null; then
                print_warning "stress-ng process terminated, memory pressure test may have ended early"
            fi
            
            # Check for lock contention signs
            if tail -n 20 "$LOG_DIR/kernel/dmesg_live.log" 2>/dev/null | grep -q "blocked.*jbd2"; then
                print_warning "Detected possible JBD2 lock contention!"
            fi
        fi
        
        sleep 1
    done
    echo
    
    # Stop monitoring
    stop_monitoring
    
    # Stop test processes
    stop_all_tests
    
    # Cleanup error device
    if [ "$error_device_available" = "true" ]; then
        cleanup_error_device
    fi
}

# Stop all tests
stop_all_tests() {
    print_info "Stopping all test processes..."
    
    # Read and kill recorded PIDs
    for pid_file in "$LOG_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null && sleep 2
                kill -KILL "$pid" 2>/dev/null 2>/dev/null || true
            fi
        fi
    done
    
    # Also kill any remaining fio processes
    pkill -f "fio" 2>/dev/null || true
    
    # Clean up test directory
    cleanup_test_dir
}

# Generate test report
generate_report() {
    print_info "Generating JBD2 lock contention test report..."
    
    REPORT_FILE="$LOG_DIR/jbd2_lock_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    # Collect key information
    local lock_detections=0
    local kswapd_blocks=0
    local jbd2_activities=0
    local io_errors=0
    local blk_update_errors=0
    
    if [ -f "$LOG_DIR/lock_detections.log" ]; then
        lock_detections=$(grep -c "Detected jbd2_log_wait_commit blocking" "$LOG_DIR/lock_detections.log" || echo 0)
    fi
    
    if [ -f "$LOG_DIR/kswapd_blocked.log" ]; then
        kswapd_blocks=$(grep -c "Detected kswapd blocking" "$LOG_DIR/kswapd_blocked.log" || echo 0)
    fi
    
    if [ -f "$LOG_DIR/jbd2_activity.log" ]; then
        jbd2_activities=$(grep -c "Detected jbd2 checkpoint activity" "$LOG_DIR/jbd2_activity.log" || echo 0)
    fi
    
    if [ -f "$LOG_DIR/io_errors.log" ]; then
        io_errors=$(grep -c "Detected general IO error" "$LOG_DIR/io_errors.log" || echo 0)
        blk_update_errors=$(grep -c "Detected blk_update_request: IO error" "$LOG_DIR/io_errors.log" || echo 0)
    fi
    
    cat > "$REPORT_FILE" << EOF
JBD2 Lock Contention and IO Error Stress Test Report
Generated: $(date)
Test Duration: ${RUN_TIME} seconds
System Info: $(uname -a)

=== Test Configuration ===
Memory Pressure Size: ${MEMORY_SIZE}
Memory Pressure Threads: ${MEMORY_THREADS}
File Operations Count: ${FILE_COUNT}
IO Threads: ${IO_THREADS}
Test Directory: ${TEST_DIR}

=== Lock Contention Detection Results ===
JBD2 Lock Wait Detections: ${lock_detections}
kswapd Blocking Detections: ${kswapd_blocks}
JBD2 Checkpoint Activities: ${jbd2_activities}

=== IO Error Detection Results ===
blk_update_request IO Errors: ${blk_update_errors}
General IO Errors: ${io_errors}

=== System Resource Usage Summary ===
$(sar -u -f "$LOG_DIR/system/cpu.log" 2>/dev/null | tail -5 || echo "CPU data unavailable")

$(sar -r -f "$LOG_DIR/system/memory.log" 2>/dev/null | tail -5 || echo "Memory data unavailable")

$(sar -d -f "$LOG_DIR/system/disk.log" 2>/dev/null | tail -5 || echo "Disk data unavailable")

=== Key Kernel Messages ===
$(tail -20 "$LOG_DIR/kernel/dmesg_live.log" 2>/dev/null || echo "Kernel messages unavailable")

=== Test Conclusion ===
$(if [ "${lock_detections:-0}" -gt 0 ]; then
    echo "✓ Successfully triggered JBD2 lock contention scenario"
    echo "  Detected ${lock_detections} lock wait events"
else
    echo "✗ No significant JBD2 lock contention detected"
    echo "  Possible reasons:"
    echo "  1. System has sufficient memory, kswapd not frequently awakened"
    echo "  2. Different filesystem configuration"
    echo "  3. Kernel version may have fixed the issue"
fi)

$(if [ "${kswapd_blocks:-0}" -gt 0 ]; then
    echo "✓ Detected kswapd blocking events ${kswapd_blocks} times"
else
    echo "✗ No kswapd blocking detected"
fi)

$(if [ "${jbd2_activities:-0}" -gt 0 ]; then
    echo "✓ Detected JBD2 checkpoint activity ${jbd2_activities} times"
else
    echo "✗ No JBD2 checkpoint activity detected"
fi)

$(if [ "${blk_update_errors:-0}" -gt 0 ]; then
    echo "✓ SUCCESS: Triggered blk_update_request: IO error messages!"
    echo "  Detected ${blk_update_errors} blk_update_request IO errors"
else
    echo "✗ No blk_update_request IO errors detected"
    echo "  The aggressive I/O test did not trigger the expected kernel errors"
    echo "  Consider:"
    echo "  1. Increasing test duration with -t option"
    echo "  2. Increasing memory pressure with -m option"
    echo "  3. Increasing I/O intensity with -i option"
    echo "  4. Testing on different storage hardware"
fi)

$(if [ "${io_errors:-0}" -gt 0 ]; then
    echo "✓ Detected ${io_errors} general IO errors"
else
    echo "✗ No general IO errors detected"
fi)

=== Recommendations ===
1. Check /var/log/kern.log or dmesg for detailed kernel messages
2. Monitor system memory usage to ensure enough pressure triggers kswapd
3. If lock contention not triggered, try increasing memory pressure or file operations count
4. Check if filesystem is ext4 with journal enabled
5. Consider using older kernel version to reproduce historical issue
6. For IO errors: Check storage device health and connection

=== Next Steps ===
1. Analyze detailed logs in $LOG_DIR directory
2. Check performance impact related to lock contention
3. Evaluate system stability under pressure
4. Review IO error patterns in $LOG_DIR/io_errors_detailed.log
EOF
    
    print_success "Report generated: $REPORT_FILE"
    
    # Show brief results
    echo -e "\n${GREEN}=== Test Completed ===${NC}"
    echo "Detailed logs available at: $LOG_DIR"
    echo "Test report: $REPORT_FILE"
    if [ "${blk_update_errors:-0}" -gt 0 ]; then
        echo -e "${GREEN}✓ Successfully triggered blk_update_request: IO error messages!${NC}"
    else
        echo -e "${YELLOW}⚠ No blk_update_request IO errors detected${NC}"
    fi
}

# Cleanup function
cleanup() {
    print_info "Performing cleanup..."
    
    # Stop all child processes
    stop_all_tests
    
    # Cleanup error device if it exists
    cleanup_error_device
    
    # Stop monitoring processes
    pkill -f "sar" 2>/dev/null || true
    pkill -f "dmesg" 2>/dev/null || true
    
    # Wait for processes to end
    sleep 2
}

# Main function
main() {
    # Set trap to catch interrupt signals
    trap cleanup EXIT INT TERM
    
    print_info "Starting JBD2 lock contention stress test"
    
    # Check dependencies
    check_dependencies
    
    # Create log directory
    create_log_dir
    
    # Run tests
    run_all_tests_parallel
    
    # Generate report
    generate_report
    
    print_success "JBD2 lock contention stress test completed!"
}

# Script usage
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -t <seconds>  Test run time (default: 600)"
    echo "  -m <size>     Memory test size (default: 4G)"
    echo "  -f <count>    Number of files to create/delete (default: 100000)"
    echo "  -i <threads>  IO thread count (default: 8)"
    echo "  -j <threads>  Memory pressure thread count (default: 4)"
    echo "  -d <dir>      Test file directory (default: ./jbd2_test_files)"
    echo "  -l <dir>      Log directory (default: ./jbd2_lock_logs)"
    echo "  -h            Show this help message"
    exit 0
}

# Parse command line arguments
while getopts "t:m:f:i:j:d:l:h" opt; do
    case $opt in
        t) RUN_TIME="$OPTARG" ;;
        m) MEMORY_SIZE="$OPTARG" ;;
        f) FILE_COUNT="$OPTARG" ;;
        i) IO_THREADS="$OPTARG" ;;
        j) MEMORY_THREADS="$OPTARG" ;;
        d) TEST_DIR="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        h) usage ;;
        *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# Run main function
main "$@"
