#!/bin/bash
# NFS Real-time Bidirectional Synchronization Script - FIXED VERSION
# Creates a unified shared folder using NFS with instant updates on both systems

# Configuration
SHARED_FOLDER="/var/log/timble"
LOCAL_NFS_EXPORT="/var/log/nfs-local-export"
REMOTE_NFS_MOUNT="/var/log/nfs-remote-mount"
SYSTEM1_IP="10.20.40.153"  # Replace with actual IPs
SYSTEM2_IP="10.20.40.154"   # Replace with actual IPs
LOG_FILE="/var/log/nfs-realtime-sync.log"
CURRENT_SYSTEM=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Detect current system
detect_system() {
    local current_ip=$(hostname -I | awk '{print $1}')
    
    if [[ "$current_ip" == "$SYSTEM1_IP" ]]; then
        CURRENT_SYSTEM="system1"
        REMOTE_IP="$SYSTEM2_IP"
    elif [[ "$current_ip" == "$SYSTEM2_IP" ]]; then
        CURRENT_SYSTEM="system2"
        REMOTE_IP="$SYSTEM1_IP"
    else
        echo -e "${YELLOW}Warning: Could not auto-detect system. Please run with --system1 or --system2${NC}"
        CURRENT_SYSTEM="unknown"
    fi
    
    echo -e "${BLUE}Detected system: $CURRENT_SYSTEM${NC}"
}

# Check OS and set package manager
detect_os() {
    if [ -f /etc/redhat-release ]; then
        if grep -q "release 8\|release 9" /etc/redhat-release; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        NFS_USER="nfsnobody"
        NFS_SERVICES="nfs-server rpcbind"
    elif [ -f /etc/debian_version ]; then
        PKG_MGR="apt"
        NFS_USER="nobody"
        NFS_SERVICES="nfs-kernel-server rpcbind"
    else
        echo -e "${RED}Unsupported OS${NC}"
        exit 1
    fi
}

# Install NFS packages
install_nfs() {
    echo -e "${BLUE}Installing NFS packages...${NC}"
    detect_os
    
    case $PKG_MGR in
        "dnf")
            sudo dnf install -y nfs-utils rpcbind inotify-tools
            ;;
        "yum")
            sudo yum install -y nfs-utils rpcbind inotify-tools
            ;;
        "apt")
            sudo apt update
            sudo apt install -y nfs-kernel-server nfs-common rpcbind inotify-tools
            ;;
    esac
    
    echo -e "${GREEN}✓ NFS packages installed${NC}"
}

# Setup NFS server
setup_nfs_server() {
    echo -e "${BLUE}Setting up NFS server...${NC}"
    detect_os
    
    # Create local export directory
    sudo mkdir -p "$LOCAL_NFS_EXPORT"
    
    # Handle user/group differences between distros
    if id "$NFS_USER" &>/dev/null; then
        sudo chown $NFS_USER:$NFS_USER "$LOCAL_NFS_EXPORT"
    else
        echo -e "${YELLOW}Warning: $NFS_USER user not found, using root ownership${NC}"
        sudo chown root:root "$LOCAL_NFS_EXPORT"
    fi
    sudo chmod 755 "$LOCAL_NFS_EXPORT"
    
    # Backup existing exports
    if [ -f /etc/exports ]; then
        sudo cp /etc/exports /etc/exports.backup.$(date +%s)
    fi
    
    # Configure exports
    if [[ "$CURRENT_SYSTEM" == "system1" ]]; then
        echo "$LOCAL_NFS_EXPORT $SYSTEM2_IP(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
    elif [[ "$CURRENT_SYSTEM" == "system2" ]]; then
        echo "$LOCAL_NFS_EXPORT $SYSTEM1_IP(rw,sync,no_root_squash,no_subtree_check)" | sudo tee -a /etc/exports
    fi
    
    # Start NFS services with proper error handling
    for service in $NFS_SERVICES; do
        if systemctl list-unit-files | grep -q "^$service"; then
            sudo systemctl enable $service
            sudo systemctl start $service
            if ! systemctl is-active --quiet $service; then
                echo -e "${RED}Failed to start $service${NC}"
                systemctl status $service
            else
                echo -e "${GREEN}✓ $service started${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: $service not found${NC}"
        fi
    done
    
    # Export shares if exportfs is available
    if command -v exportfs >/dev/null 2>&1; then
        sudo exportfs -arv
    else
        echo -e "${YELLOW}Warning: exportfs command not found${NC}"
    fi
    
    # Note: Firewall configuration removed - handle manually if needed
    echo -e "${YELLOW}Note: Firewall configuration skipped - configure manually if needed${NC}"
    
    echo -e "${GREEN}✓ NFS server configured${NC}"
}

# Setup NFS client
setup_nfs_client() {
    echo -e "${BLUE}Setting up NFS client...${NC}"
    detect_os
    
    # Create remote mount directory
    sudo mkdir -p "$REMOTE_NFS_MOUNT"
    
    # Start rpcbind if available
    if systemctl list-unit-files | grep -q "^rpcbind"; then
        sudo systemctl enable rpcbind
        sudo systemctl start rpcbind
    else
        echo -e "${YELLOW}Warning: rpcbind service not found${NC}"
    fi
    
    # Test mount with better error handling
    if [[ "$CURRENT_SYSTEM" == "system1" ]]; then
        REMOTE_MOUNT_TARGET="$SYSTEM2_IP:$LOCAL_NFS_EXPORT"
    elif [[ "$CURRENT_SYSTEM" == "system2" ]]; then
        REMOTE_MOUNT_TARGET="$SYSTEM1_IP:$LOCAL_NFS_EXPORT"
    fi
    
    # Check if mount helper exists
    if [ ! -f /sbin/mount.nfs ]; then
        echo -e "${YELLOW}Warning: NFS mount helper not found. Installing additional packages...${NC}"
        case $PKG_MGR in
            "dnf"|"yum")
                sudo $PKG_MGR install -y nfs-utils
                ;;
            "apt")
                sudo apt install -y nfs-common
                ;;
        esac
    fi
    
    # Attempt mount
    if sudo mount -t nfs "$REMOTE_MOUNT_TARGET" "$REMOTE_NFS_MOUNT"; then
        echo -e "${GREEN}✓ Remote NFS mounted successfully${NC}"
        
        # Add to fstab for permanent mount
        if ! grep -q "$REMOTE_NFS_MOUNT" /etc/fstab; then
            echo "$REMOTE_MOUNT_TARGET $REMOTE_NFS_MOUNT nfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
            sudo systemctl daemon-reload
        fi
    else
        echo -e "${RED}Failed to mount remote NFS. Check network connectivity and remote NFS server.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ NFS client configured${NC}"
}

# Create unified shared folder using bind mount (simpler approach)
create_unified_folder() {
    echo -e "${BLUE}Creating unified shared folder...${NC}"
    
    # Remove existing shared folder if it exists
    sudo umount "$SHARED_FOLDER" 2>/dev/null || true
    sudo mkdir -p "$SHARED_FOLDER"
    
    # Use bind mount to link local export to shared folder
    if sudo mount --bind "$LOCAL_NFS_EXPORT" "$SHARED_FOLDER"; then
        echo -e "${GREEN}✓ Unified shared folder created at $SHARED_FOLDER${NC}"
    else
        echo -e "${RED}Failed to create unified shared folder${NC}"
        return 1
    fi
}

# Start real-time sync monitoring
start_realtime_sync() {
    echo -e "${BLUE}Starting real-time NFS sync monitoring...${NC}"
    
    # Check if inotify-tools is available
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo -e "${RED}inotify-tools not installed. Please run: $0 install${NC}"
        return 1
    fi
    
    # Create sync script
    cat << 'SYNC_SCRIPT' | sudo tee /usr/local/bin/nfs-sync-daemon > /dev/null
#!/bin/bash
LOCAL_EXPORT="/var/log/nfs-local-export"
REMOTE_MOUNT="/var/log/nfs-remote-mount"
SHARED_FOLDER="/var/log/timble"
LOG_FILE="/var/log/nfs-realtime-sync.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Create directories if they don't exist
mkdir -p "$LOCAL_EXPORT" "$REMOTE_MOUNT" "$SHARED_FOLDER"

# Monitor local export for changes
inotifywait -m -r -e create,modify,delete,move "$LOCAL_EXPORT" --format '%w%f %e' 2>/dev/null |
while read file_path event; do
    rel_path="${file_path#$LOCAL_EXPORT/}"
    
    # Skip temporary files and hidden files
    if [[ "$rel_path" == *"~"* ]] || [[ "$rel_path" == *".tmp"* ]] || [[ "$rel_path" == .*/* ]]; then
        continue
    fi
    
    log "Local change detected: $event on $rel_path"
    
    case "$event" in
        *CREATE*|*MODIFY*)
            if [ -f "$file_path" ] && [ -d "$REMOTE_MOUNT" ]; then
                # Copy to remote via NFS
                cp "$file_path" "$REMOTE_MOUNT/" 2>/dev/null && \
                log "Synced to remote: $rel_path" || \
                log "Failed to sync to remote: $rel_path"
            fi
            ;;
        *DELETE*)
            if [ -d "$REMOTE_MOUNT" ]; then
                # Remove from remote via NFS
                rm -f "$REMOTE_MOUNT/$rel_path" 2>/dev/null && \
                log "Deleted from remote: $rel_path" || \
                log "Failed to delete from remote: $rel_path"
            fi
            ;;
    esac
done
SYNC_SCRIPT
    
    sudo chmod +x /usr/local/bin/nfs-sync-daemon
    
    # Kill existing daemon if running
    sudo pkill -f "nfs-sync-daemon" 2>/dev/null || true
    
    # Start the daemon in background
    nohup sudo /usr/local/bin/nfs-sync-daemon > /dev/null 2>&1 &
    
    log "Real-time NFS sync started"
    echo -e "${GREEN}✓ Real-time sync monitoring started${NC}"
}

# Stop sync monitoring
stop_sync() {
    echo -e "${YELLOW}Stopping NFS sync monitoring...${NC}"
    sudo pkill -f "nfs-sync-daemon" 2>/dev/null || true
    sudo pkill -f "inotifywait.*$LOCAL_NFS_EXPORT" 2>/dev/null || true
    log "Real-time NFS sync stopped"
    echo -e "${GREEN}✓ Sync monitoring stopped${NC}"
}

# Show status
show_status() {
    echo -e "${BLUE}=== NFS Real-time Sync Status ===${NC}"
    echo "Current System: $CURRENT_SYSTEM"
    echo "Local Export: $LOCAL_NFS_EXPORT"
    echo "Remote Mount: $REMOTE_NFS_MOUNT"
    echo "Shared Folder: $SHARED_FOLDER"
    echo ""
    
    echo "=== NFS Mounts ==="
    mount | grep nfs || echo "No NFS mounts found"
    echo ""
    
    echo "=== NFS Exports ==="
    if command -v exportfs >/dev/null 2>&1; then
        sudo exportfs -v || echo "No exports found"
    else
        echo "exportfs command not available"
    fi
    echo ""
    
    echo "=== Service Status ==="
    for service in nfs-server rpcbind; do
        if systemctl list-unit-files | grep -q "^$service"; then
            status=$(systemctl is-active $service 2>/dev/null || echo "inactive")
            echo "$service: $status"
        fi
    done
    echo ""
    
    echo "=== Process Status ==="
    if pgrep -f "nfs-sync-daemon" >/dev/null; then
        echo -e "Sync Daemon: ${GREEN}RUNNING${NC} (PID: $(pgrep -f nfs-sync-daemon))"
    else
        echo -e "Sync Daemon: ${RED}STOPPED${NC}"
    fi
    
    echo ""
    echo "=== Directory Contents ==="
    echo "Local Export ($LOCAL_NFS_EXPORT):"
    ls -la "$LOCAL_NFS_EXPORT" 2>/dev/null || echo "Directory not accessible"
    
    echo ""
    echo "Remote Mount ($REMOTE_NFS_MOUNT):"
    ls -la "$REMOTE_NFS_MOUNT" 2>/dev/null || echo "Directory not accessible"
    
    echo ""
    echo "Shared Folder ($SHARED_FOLDER):"
    ls -la "$SHARED_FOLDER" 2>/dev/null || echo "Directory not accessible"
}

# Test the setup
test_setup() {
    echo -e "${BLUE}Testing NFS bidirectional setup...${NC}"
    
    # Test 1: Create file in local export
    test_file="nfs-test-$(date +%s).txt"
    echo "Test from $CURRENT_SYSTEM at $(date)" | sudo tee "$LOCAL_NFS_EXPORT/$test_file" > /dev/null
    
    # Wait and check if it appears in remote mount
    sleep 2
    if [ -f "$REMOTE_NFS_MOUNT/$test_file" ]; then
        echo -e "${GREEN}✓ Local to remote sync working${NC}"
    else
        echo -e "${RED}✗ Local to remote sync failed${NC}"
    fi
    
    # Test 2: Check shared folder
    if [ -f "$SHARED_FOLDER/$test_file" ]; then
        echo -e "${GREEN}✓ Shared folder access working${NC}"
    else
        echo -e "${RED}✗ Shared folder access failed${NC}"
    fi
    
    echo ""
    echo "Test file created: $test_file"
    echo "Check on the remote system to verify bidirectional sync"
}

# Clean up
cleanup() {
    echo -e "${BLUE}Cleaning up NFS setup...${NC}"
    
    stop_sync
    
    # Unmount everything
    sudo umount "$SHARED_FOLDER" 2>/dev/null || true
    sudo umount "$REMOTE_NFS_MOUNT" 2>/dev/null || true
    
    # Remove from fstab
    sudo sed -i "\|$REMOTE_NFS_MOUNT|d" /etc/fstab
    
    # Remove sync daemon
    sudo rm -f /usr/local/bin/nfs-sync-daemon
    
    echo -e "${GREEN}✓ Cleanup completed${NC}"
}

# Diagnostic function
diagnose() {
    echo -e "${BLUE}=== NFS Diagnostic Information ===${NC}"
    
    echo "1. System Information:"
    uname -a
    cat /etc/os-release | head -5
    echo ""
    
    echo "2. Network Connectivity:"
    if [[ "$CURRENT_SYSTEM" == "system1" ]]; then
        ping -c 2 "$SYSTEM2_IP" 2>/dev/null && echo "✓ Can reach System 2" || echo "✗ Cannot reach System 2"
    elif [[ "$CURRENT_SYSTEM" == "system2" ]]; then
        ping -c 2 "$SYSTEM1_IP" 2>/dev/null && echo "✓ Can reach System 1" || echo "✗ Cannot reach System 1"
    fi
    echo ""
    
    echo "3. Required Packages:"
    for pkg in nfs-utils rpcbind inotify-tools; do
        if rpm -q $pkg >/dev/null 2>&1 || dpkg -l | grep -q $pkg 2>/dev/null; then
            echo "✓ $pkg installed"
        else
            echo "✗ $pkg not installed"
        fi
    done
    echo ""
    
    echo "4. Required Commands:"
    for cmd in mount.nfs exportfs showmount inotifywait; do
        if command -v $cmd >/dev/null 2>&1; then
            echo "✓ $cmd available"
        else
            echo "✗ $cmd not available"
        fi
    done
    echo ""
    
    echo "5. Service Status:"
    for service in nfs-server rpcbind; do
        if systemctl list-unit-files | grep -q "^$service"; then
            status=$(systemctl is-active $service 2>/dev/null || echo "inactive")
            enabled=$(systemctl is-enabled $service 2>/dev/null || echo "disabled")
            echo "$service: $status ($enabled)"
        else
            echo "$service: not found"
        fi
    done
}

# Main script logic
case "$1" in
    "--system1")
        CURRENT_SYSTEM="system1"
        REMOTE_IP="$SYSTEM2_IP"
        ;;
    "--system2")
        CURRENT_SYSTEM="system2"
        REMOTE_IP="$SYSTEM1_IP"
        ;;
    *)
        detect_system
        ;;
esac

# Command handling
case "$2" in
    "install")
        install_nfs
        ;;
    "setup")
        setup_nfs_server
        setup_nfs_client
        create_unified_folder
        ;;
    "start-sync")
        start_realtime_sync
        ;;
    "stop-sync")
        stop_sync
        ;;
    "status")
        show_status
        ;;
    "test")
        test_setup
        ;;
    "cleanup")
        cleanup
        ;;
    "diagnose")
        diagnose
        ;;
    *)
        echo -e "${BLUE}NFS Real-time Bidirectional Synchronization - FIXED VERSION${NC}"
        echo ""
        echo "Usage: $0 [--system1|--system2] {install|setup|start-sync|stop-sync|status|test|cleanup|diagnose}"
        echo ""
        echo "System Selection:"
        echo "  --system1    Run as System 1"
        echo "  --system2    Run as System 2"
        echo "  (auto)       Auto-detect based on IP"
        echo ""
        echo "Commands:"
        echo "  install      Install NFS packages"
        echo "  setup        Complete NFS setup"
        echo "  start-sync   Start real-time sync monitoring"
        echo "  stop-sync    Stop real-time sync monitoring"
        echo "  status       Show current status"
        echo "  test         Test the bidirectional setup"
        echo "  cleanup      Remove all NFS setup"
        echo "  diagnose     Show diagnostic information"
        echo ""
        echo -e "${YELLOW}Quick Setup:${NC}"
        echo "1. Edit script and set SYSTEM1_IP and SYSTEM2_IP correctly"
        echo "2. On System 1: $0 --system1 install"
        echo "3. On System 1: $0 --system1 setup"
        echo "4. On System 2: $0 --system2 install"
        echo "5. On System 2: $0 --system2 setup"
        echo "6. On both: $0 start-sync"
        echo ""
        echo -e "${RED}Troubleshooting:${NC}"
        echo "Run '$0 diagnose' to check system requirements"
        ;;
esac