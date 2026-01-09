#!/usr/bin/env bash
# docker-swarm-bootstrap.sh
# Remote execution script for bootstrapping Docker Swarm with Wireguard mesh network.
# This script is designed to be run from a "satellite" machine that orchestrates
# the setup of multiple nodes in a Docker Swarm cluster over Wireguard VPN.
#
# Features:
# - Remote execution via SSH from satellite machine with strict host key verification
# - Wireguard VPN mesh network setup (kernel mode)
# - UFW firewall configuration for manager/worker nodes
# - Docker installation and Swarm initialization
# - Docker user creation and configuration
#
# Prerequisites:
# - SSH access to all nodes from satellite machine
# - All nodes must be Debian-based (Ubuntu/Debian)
# - SSH credentials stored in .ssh-credentials folder
set -euo pipefail

# ============================================================================
# NODE DEFINITIONS - Define your swarm nodes here
# Format: "hostname:role:public_ip:wireguard_ip"
# Roles: manager, worker
# ============================================================================
declare -a SWARM_NODES=(
  # Example entries - modify these for your setup:
  # "swarm-manager-01:manager:203.0.113.10:10.50.0.1"
  # "swarm-manager-02:manager:203.0.113.11:10.50.0.2"
  # "swarm-manager-03:manager:203.0.113.12:10.50.0.3"
  # "swarm-worker-01:worker:203.0.113.20:10.50.0.10"
  # "swarm-worker-02:worker:203.0.113.21:10.50.0.11"
)

# ============================================================================
# CONFIGURATION
# ============================================================================
TARGET_USER="docker"                    # User to create/configure for Docker
DOCKER_INSTALL_URL="https://get.docker.com"
WIREGUARD_PORT="51821"                  # Wireguard listen port
WIREGUARD_SUBNET="10.50.0.0/24"         # Wireguard network subnet
WIREGUARD_INTERFACE="wg0"               # Wireguard interface name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CREDENTIALS_DIR="${SCRIPT_DIR}/.ssh-credentials"
SSH_KNOWN_HOSTS_FILE="${SCRIPT_DIR}/.ssh-credentials/known_hosts"
SSH_OPTIONS="-o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}"

# Temporary storage for generated keys
declare -A NODE_PRIVATE_KEYS
declare -A NODE_PUBLIC_KEYS

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
debug() { printf '\033[1;36m[DEBUG]\033[0m %s\n' "$*"; }

# ============================================================================
# USAGE
# ============================================================================
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Docker Swarm Bootstrap Script with Wireguard Mesh Network

This script remotely configures multiple nodes to form a Docker Swarm cluster
connected via a Wireguard VPN mesh network.

Options:
  --check-only            Only check prerequisites, don't make changes
  --skip-wireguard        Skip Wireguard installation and configuration
  --skip-ufw              Skip UFW firewall configuration
  --skip-docker           Skip Docker installation
  --skip-swarm            Skip Docker Swarm setup
  --user <USERNAME>       Target user to create (default: docker)
  -h, --help              Show this help message

Node Definition:
  Edit the SWARM_NODES array at the top of this script to define your nodes.
  Format: "hostname:role:public_ip:wireguard_ip"
  
  Example:
    SWARM_NODES=(
      "swarm-manager-01:manager:203.0.113.10:10.50.0.1"
      "swarm-worker-01:worker:203.0.113.20:10.50.0.10"
    )

SSH Credentials:
  Store SSH credentials in ${SSH_CREDENTIALS_DIR}/
  Each file should be named with a "." prefix followed by the hostname:
    .swarm-manager-01
    .swarm-worker-01
  
  File format (one of the following):
    - Private key file path
    - Or create a file containing: user:password (less secure)

SSH Security:
  This script uses strict SSH host key verification to prevent man-in-the-middle
  attacks. On first run, the script will scan and store host keys for all nodes
  in ${SSH_CREDENTIALS_DIR}/known_hosts. Subsequent runs will verify hosts
  against these stored keys.

Examples:
  # Full setup
  $0

  # Check prerequisites only
  $0 --check-only

  # Skip Wireguard (nodes already have VPN)
  $0 --skip-wireguard

EOF
  exit 0
}

# ============================================================================
# PARSE COMMAND LINE ARGUMENTS
# ============================================================================
CHECK_ONLY=false
SKIP_WIREGUARD=false
SKIP_UFW=false
SKIP_DOCKER=false
SKIP_SWARM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --skip-wireguard)
      SKIP_WIREGUARD=true
      shift
      ;;
    --skip-ufw)
      SKIP_UFW=true
      shift
      ;;
    --skip-docker)
      SKIP_DOCKER=true
      shift
      ;;
    --skip-swarm)
      SKIP_SWARM=true
      shift
      ;;
    --user)
      TARGET_USER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      err "Unknown option: $1"
      usage
      ;;
  esac
done

# ============================================================================
# VALIDATION
# ============================================================================
validate_nodes() {
  log "Validating node definitions..."
  
  if [ ${#SWARM_NODES[@]} -eq 0 ]; then
    err "No nodes defined in SWARM_NODES array. Please edit the script to add nodes."
    exit 1
  fi
  
  local manager_count=0
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    if [ -z "$hostname" ] || [ -z "$role" ] || [ -z "$public_ip" ] || [ -z "$wg_ip" ]; then
      err "Invalid node definition: $node"
      err "Format must be: hostname:role:public_ip:wireguard_ip"
      exit 1
    fi
    
    if [ "$role" != "manager" ] && [ "$role" != "worker" ]; then
      err "Invalid role '$role' for node '$hostname'. Must be 'manager' or 'worker'."
      exit 1
    fi
    
    if [ "$role" = "manager" ]; then
      ((manager_count++))
    fi
    
    log "  Node: $hostname (role=$role, public=$public_ip, wg=$wg_ip)"
  done
  
  if [ $manager_count -eq 0 ]; then
    err "At least one manager node is required."
    exit 1
  fi
  
  log "Validated ${#SWARM_NODES[@]} nodes ($manager_count managers)"
}

# ============================================================================
# SSH KNOWN HOSTS MANAGEMENT
# ============================================================================
initialize_known_hosts() {
  log "Initializing SSH known_hosts file..."
  
  # Ensure SSH credentials directory exists
  if [ ! -d "$SSH_CREDENTIALS_DIR" ]; then
    mkdir -p "$SSH_CREDENTIALS_DIR"
    chmod 700 "$SSH_CREDENTIALS_DIR"
  fi
  
  # Create known_hosts file if it doesn't exist
  touch "$SSH_KNOWN_HOSTS_FILE"
  chmod 600 "$SSH_KNOWN_HOSTS_FILE"
  
  log "Scanning and adding SSH host keys for all nodes..."
  local added_count=0
  local failed_count=0
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    # Check if host key already exists in known_hosts
    if ssh-keygen -F "$public_ip" -f "$SSH_KNOWN_HOSTS_FILE" >/dev/null 2>&1; then
      log "  ✓ $hostname ($public_ip) - Host key already in known_hosts"
      continue
    fi
    
    # Scan and add host key
    log "  Scanning host key for $hostname ($public_ip)..."
    if ssh-keyscan -H -T 10 "$public_ip" >> "$SSH_KNOWN_HOSTS_FILE" 2>/dev/null; then
      ((added_count++))
      log "  ✓ $hostname ($public_ip) - Host key added to known_hosts"
    else
      ((failed_count++))
      err "  ✗ $hostname ($public_ip) - Failed to scan host key"
    fi
  done
  
  if [ $failed_count -gt 0 ]; then
    err "Failed to add $failed_count host key(s) to known_hosts."
    err "Please ensure all nodes are reachable and SSH is running."
    exit 1
  fi
  
  log "Added $added_count new host key(s) to known_hosts"
  log "SSH host key verification is now enabled for all connections"
}

# ============================================================================
# SSH HELPER FUNCTIONS
# ============================================================================
get_ssh_credentials() {
  local hostname="$1"
  local cred_file="${SSH_CREDENTIALS_DIR}/.${hostname}"
  
  if [ ! -f "$cred_file" ]; then
    err "SSH credentials file not found: $cred_file"
    err "Please create the file with SSH private key path or user:password"
    return 1
  fi
  
  echo "$cred_file"
}

ssh_to_node() {
  local hostname="$1"
  local public_ip="$2"
  shift 2
  local cmd="$*"
  
  local cred_file
  cred_file=$(get_ssh_credentials "$hostname") || return 1
  
  local cred_content
  cred_content=$(cat "$cred_file")
  
  # Check if it's a key file path or user:password
  if [ -f "$cred_content" ]; then
    # It's a path to a private key file
    local key_file="$cred_content"
    local ssh_user="root"
    # Check if there's a second line with username
    if [ "$(wc -l < "$cred_file")" -ge 2 ]; then
      ssh_user=$(sed -n '2p' "$cred_file")
    fi
    ssh $SSH_OPTIONS -i "$key_file" "${ssh_user}@${public_ip}" "$cmd"
  elif [[ "$cred_content" == *":"* ]]; then
    # It's user:password format - use sshpass
    local ssh_user="${cred_content%%:*}"
    local ssh_pass="${cred_content#*:}"
    if ! command -v sshpass >/dev/null 2>&1; then
      err "sshpass is required for password-based SSH. Install it on the satellite machine."
      return 1
    fi
    sshpass -p "$ssh_pass" ssh $SSH_OPTIONS "${ssh_user}@${public_ip}" "$cmd"
  else
    # Assume it's a private key file path
    ssh $SSH_OPTIONS -i "$cred_content" "root@${public_ip}" "$cmd"
  fi
}

scp_to_node() {
  local hostname="$1"
  local public_ip="$2"
  local local_file="$3"
  local remote_path="$4"
  
  local cred_file
  cred_file=$(get_ssh_credentials "$hostname") || return 1
  
  local cred_content
  cred_content=$(cat "$cred_file")
  
  if [ -f "$cred_content" ]; then
    local key_file="$cred_content"
    local ssh_user="root"
    if [ "$(wc -l < "$cred_file")" -ge 2 ]; then
      ssh_user=$(sed -n '2p' "$cred_file")
    fi
    scp $SSH_OPTIONS -i "$key_file" "$local_file" "${ssh_user}@${public_ip}:${remote_path}"
  elif [[ "$cred_content" == *":"* ]]; then
    local ssh_user="${cred_content%%:*}"
    local ssh_pass="${cred_content#*:}"
    sshpass -p "$ssh_pass" scp $SSH_OPTIONS "$local_file" "${ssh_user}@${public_ip}:${remote_path}"
  else
    scp $SSH_OPTIONS -i "$cred_content" "$local_file" "root@${public_ip}:${remote_path}"
  fi
}

# ============================================================================
# CHECK SSH CONNECTIVITY
# ============================================================================
check_ssh_connectivity() {
  log "Checking SSH connectivity to all nodes..."
  
  local failed=0
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    if ssh_to_node "$hostname" "$public_ip" "echo 'SSH OK'" >/dev/null 2>&1; then
      log "  ✓ $hostname ($public_ip) - SSH connection successful"
    else
      err "  ✗ $hostname ($public_ip) - SSH connection failed"
      ((failed++))
    fi
  done
  
  if [ $failed -gt 0 ]; then
    err "Failed to connect to $failed node(s). Please check SSH credentials."
    exit 1
  fi
  
  log "All nodes are reachable via SSH"
}

# ============================================================================
# CHECK DEBIAN-BASED DISTRO
# ============================================================================
check_debian_distro() {
  log "Checking if all nodes are Debian-based..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    local distro_id
    distro_id=$(ssh_to_node "$hostname" "$public_ip" "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"' | tr '[:upper:]' '[:lower:]'")
    
    case "$distro_id" in
      ubuntu|debian)
        log "  ✓ $hostname - Debian-based ($distro_id)"
        ;;
      *)
        err "  ✗ $hostname - Not Debian-based ($distro_id). This script requires Ubuntu/Debian."
        exit 1
        ;;
    esac
  done
}

# ============================================================================
# SYSTEM UPDATE FUNCTION
# ============================================================================
run_system_update() {
  log "Running system updates on all nodes..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    log "  Updating $hostname..."
    ssh_to_node "$hostname" "$public_ip" "sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y" || {
      warn "System update on $hostname completed with warnings"
    }
  done
  
  log "System updates completed on all nodes"
}

# ============================================================================
# WIREGUARD INSTALLATION AND CONFIGURATION
# ============================================================================
install_wireguard() {
  log "Installing Wireguard on all nodes (kernel mode)..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    log "  Installing Wireguard on $hostname..."
    ssh_to_node "$hostname" "$public_ip" "
      # Check if Wireguard is already installed
      if command -v wg >/dev/null 2>&1; then
        echo 'Wireguard is already installed'
      else
        # Install Wireguard (kernel mode)
        sudo apt update
        sudo apt install -y wireguard wireguard-tools
      fi
      
      # Create Wireguard directory if not exists
      sudo mkdir -p /etc/wireguard
      sudo chmod 700 /etc/wireguard
    "
  done
  
  log "Wireguard installation completed on all nodes"
}

generate_wireguard_keys() {
  log "Generating Wireguard keys on all nodes..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    log "  Generating keys for $hostname..."
    
    # Generate keys on the node and retrieve them
    local keys
    keys=$(ssh_to_node "$hostname" "$public_ip" "
      # Generate private key
      wg genkey | sudo tee /etc/wireguard/private.key
      sudo chmod 600 /etc/wireguard/private.key
      
      # Generate public key from private key
      sudo cat /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
      
      # Output both keys
      echo '---SEPARATOR---'
      sudo cat /etc/wireguard/private.key
      echo '---SEPARATOR---'
      sudo cat /etc/wireguard/public.key
    ")
    
    # Parse the keys
    local priv_key pub_key
    priv_key=$(echo "$keys" | awk '/---SEPARATOR---/{n++;next} n==1{print;exit}')
    pub_key=$(echo "$keys" | awk '/---SEPARATOR---/{n++;next} n==2{print;exit}')
    
    NODE_PRIVATE_KEYS["$hostname"]="$priv_key"
    NODE_PUBLIC_KEYS["$hostname"]="$pub_key"
    
    debug "  $hostname private key: ${priv_key:0:10}..."
    debug "  $hostname public key: ${pub_key:0:10}..."
  done
  
  log "Wireguard keys generated for all nodes"
}

configure_wireguard() {
  log "Configuring Wireguard mesh network..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    log "  Configuring $hostname..."
    
    local private_key="${NODE_PRIVATE_KEYS[$hostname]}"
    
    # Build the wg0.conf content
    local wg_config="[Interface]
Address = ${wg_ip}/24
ListenPort = ${WIREGUARD_PORT}
PrivateKey = ${private_key}
"
    
    # Add peer blocks for all other nodes
    for peer_node in "${SWARM_NODES[@]}"; do
      IFS=':' read -r peer_hostname peer_role peer_public_ip peer_wg_ip <<< "$peer_node"
      
      # Skip self
      if [ "$peer_hostname" = "$hostname" ]; then
        continue
      fi
      
      local peer_public_key="${NODE_PUBLIC_KEYS[$peer_hostname]}"
      
      wg_config+="
[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = ${peer_wg_ip}/32
Endpoint = ${peer_public_ip}:${WIREGUARD_PORT}
PersistentKeepalive = 25
"
    done
    
    # Write config to node
    ssh_to_node "$hostname" "$public_ip" "
      echo '${wg_config}' | sudo tee /etc/wireguard/${WIREGUARD_INTERFACE}.conf > /dev/null
      sudo chmod 600 /etc/wireguard/${WIREGUARD_INTERFACE}.conf
      
      # Enable and start Wireguard
      sudo systemctl enable wg-quick@${WIREGUARD_INTERFACE}
      sudo systemctl restart wg-quick@${WIREGUARD_INTERFACE} || sudo wg-quick up ${WIREGUARD_INTERFACE}
    "
  done
  
  log "Wireguard mesh network configured"
}

verify_wireguard_connectivity() {
  log "Verifying Wireguard mesh connectivity..."
  
  sleep 3  # Give Wireguard time to establish connections
  
  local failed=0
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    # Try to ping all other nodes via Wireguard
    for peer_node in "${SWARM_NODES[@]}"; do
      IFS=':' read -r peer_hostname peer_role peer_public_ip peer_wg_ip <<< "$peer_node"
      
      if [ "$peer_hostname" = "$hostname" ]; then
        continue
      fi
      
      if ssh_to_node "$hostname" "$public_ip" "ping -c 2 -W 3 $peer_wg_ip >/dev/null 2>&1"; then
        log "  ✓ $hostname -> $peer_hostname ($peer_wg_ip) - OK"
      else
        warn "  ✗ $hostname -> $peer_hostname ($peer_wg_ip) - FAILED"
        ((failed++))
      fi
    done
  done
  
  if [ $failed -gt 0 ]; then
    warn "Some Wireguard connections failed. Swarm may not work correctly."
  else
    log "All Wireguard connections verified successfully"
  fi
}

# ============================================================================
# UFW FIREWALL CONFIGURATION
# ============================================================================
configure_ufw() {
  log "Configuring UFW firewall on all nodes..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    log "  Configuring UFW on $hostname (role: $role)..."
    
    if [ "$role" = "manager" ]; then
      ssh_to_node "$hostname" "$public_ip" "
        # Install UFW if not present
        if ! command -v ufw >/dev/null 2>&1; then
          sudo apt update
          sudo apt install -y ufw
        fi
        
        # Reset UFW to defaults
        sudo ufw --force reset
        
        # Default policies
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        # Manager node rules
        # General access
        sudo ufw allow 22/tcp comment 'SSH'
        sudo ufw allow 443/tcp comment 'HTTPS'
        sudo ufw allow 80/tcp comment 'HTTP'
        
        # Wireguard
        sudo ufw allow 51821/udp comment 'Wireguard'
        sudo ufw allow 51820/udp comment 'Wireguard alternate'
        
        # Docker Swarm (over Wireguard interface only)
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 2377 proto tcp comment 'Docker Swarm manager'
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 7946 proto tcp comment 'Docker Swarm node communication TCP'
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 7946 proto udp comment 'Docker Swarm node communication UDP'
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 4789 proto udp comment 'Docker overlay network'
        
        # Docker API
        sudo ufw allow 2375/tcp comment 'Docker API'
        
        # Enable UFW
        sudo ufw --force enable
        sudo systemctl enable ufw
        
        # Show status
        sudo ufw status verbose
      "
    else
      # Worker node
      ssh_to_node "$hostname" "$public_ip" "
        # Install UFW if not present
        if ! command -v ufw >/dev/null 2>&1; then
          sudo apt update
          sudo apt install -y ufw
        fi
        
        # Reset UFW to defaults
        sudo ufw --force reset
        
        # Default policies
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        # Worker node rules
        # SSH
        sudo ufw allow 22/tcp comment 'SSH'
        
        # Wireguard
        sudo ufw allow 51821/udp comment 'Wireguard'
        sudo ufw allow 51820/udp comment 'Wireguard alternate'
        
        # Docker Swarm (over Wireguard interface only)
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 7946 proto tcp comment 'Docker Swarm node communication TCP'
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 7946 proto udp comment 'Docker Swarm node communication UDP'
        sudo ufw allow in on ${WIREGUARD_INTERFACE} to any port 4789 proto udp comment 'Docker overlay network'
        
        # Enable UFW
        sudo ufw --force enable
        sudo systemctl enable ufw
        
        # Show status
        sudo ufw status verbose
      "
    fi
  done
  
  log "UFW firewall configured on all nodes"
}

# ============================================================================
# PREREQUISITES INSTALLATION (kept from original script)
# ============================================================================
install_prereqs_on_node() {
  local hostname="$1"
  local public_ip="$2"
  
  ssh_to_node "$hostname" "$public_ip" '
    # Detect distribution
    if [ -f /etc/os-release ]; then
      . /etc/os-release
      DISTRO_ID="${ID:-unknown}"
      DISTRO_ID="${DISTRO_ID,,}"
    else
      DISTRO_ID="unknown"
    fi
    
    case "$DISTRO_ID" in
      ubuntu|debian)
        sudo apt-get update -y
        sudo apt-get install -y --no-install-recommends curl ca-certificates gnupg lsb-release
        ;;
      centos|rhel|rocky|almalinux)
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y curl ca-certificates gnupg2 lsb-release
        else
          sudo yum install -y curl ca-certificates gnupg2 redhat-lsb-core
        fi
        ;;
      fedora)
        sudo dnf install -y curl ca-certificates gnupg2 lsb-release
        ;;
      arch|manjaro)
        sudo pacman -Sy --noconfirm curl ca-certificates gnupg lsb-release
        ;;
      *)
        echo "Unknown distro ($DISTRO_ID), attempting to continue..."
        if ! command -v curl >/dev/null 2>&1; then
          echo "ERROR: curl not found. Please install curl."
          exit 1
        fi
        ;;
    esac
  '
}

# ============================================================================
# DOCKER INSTALLATION
# ============================================================================
install_docker_on_node() {
  local hostname="$1"
  local public_ip="$2"
  
  log "  Installing Docker on $hostname..."
  
  ssh_to_node "$hostname" "$public_ip" "
    # Install prerequisites first
    . /etc/os-release
    DISTRO_ID=\"\${ID:-unknown}\"
    DISTRO_ID=\"\${DISTRO_ID,,}\"
    
    case \"\$DISTRO_ID\" in
      ubuntu|debian)
        sudo apt-get update -y
        sudo apt-get install -y --no-install-recommends curl ca-certificates gnupg lsb-release
        ;;
    esac
    
    # Download and run Docker convenience script
    curl -fsSL ${DOCKER_INSTALL_URL} | sudo sh
    
    # Ensure docker group exists
    if ! getent group docker >/dev/null 2>&1; then
      sudo groupadd docker
    fi
    
    # Create target user if not exists
    if ! id -u ${TARGET_USER} >/dev/null 2>&1; then
      sudo useradd -m -s /bin/bash -N ${TARGET_USER}
    fi
    
    # Add user to docker group
    sudo usermod -aG docker ${TARGET_USER}
    
    # Add user to sudo group if available
    if getent group sudo >/dev/null 2>&1; then
      sudo usermod -aG sudo ${TARGET_USER}
    elif getent group wheel >/dev/null 2>&1; then
      sudo usermod -aG wheel ${TARGET_USER}
    fi
    
    # Enable and start Docker
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl enable --now docker
    fi
    
    # Create Docker persistent data directories
    sudo mkdir -p /mnt/docker/{data,secrets}
    sudo chown -R ${TARGET_USER}:${TARGET_USER} /mnt/docker/
  "
}

install_docker_all_nodes() {
  log "Installing Docker on all nodes..."
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    install_docker_on_node "$hostname" "$public_ip"
  done
  
  log "Docker installation completed on all nodes"
}

# ============================================================================
# DETECT MESH IP (prioritize wg0 for Wireguard vanilla)
# ============================================================================
detect_mesh_ip() {
  local hostname="$1"
  local public_ip="$2"
  
  ssh_to_node "$hostname" "$public_ip" '
    # Prioritize wg0 (vanilla Wireguard) first, then other mesh interfaces
    for iface in wg0 wg1 wg2 tailscale0 wt0 nebula0 tun0; do
      if ip link show "$iface" >/dev/null 2>&1; then
        ip=$(ip -4 addr show "$iface" | grep -oP "(?<=inet\s)\d+(\.\d+){3}" | head -n1)
        if [ -n "$ip" ]; then
          echo "$ip"
          exit 0
        fi
      fi
    done
    
    # Fallback: default route interface
    ip route get 8.8.8.8 2>/dev/null | awk "{print \$7; exit}"
  '
}

# ============================================================================
# DOCKER SWARM SETUP
# ============================================================================
setup_docker_swarm() {
  log "Setting up Docker Swarm cluster..."
  
  # Find the first manager node
  local first_manager_hostname=""
  local first_manager_public_ip=""
  local first_manager_wg_ip=""
  
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    if [ "$role" = "manager" ]; then
      first_manager_hostname="$hostname"
      first_manager_public_ip="$public_ip"
      first_manager_wg_ip="$wg_ip"
      break
    fi
  done
  
  log "Initializing Swarm on first manager: $first_manager_hostname"
  
  # Detect the mesh IP on the first manager
  local advertise_ip
  advertise_ip=$(detect_mesh_ip "$first_manager_hostname" "$first_manager_public_ip")
  
  if [ -z "$advertise_ip" ]; then
    err "Failed to detect advertise IP on $first_manager_hostname"
    exit 1
  fi
  
  log "  Using advertise IP: $advertise_ip"
  
  # Initialize swarm on first manager
  ssh_to_node "$first_manager_hostname" "$first_manager_public_ip" "
    if docker info 2>/dev/null | grep -q 'Swarm: active'; then
      echo 'Swarm already active, leaving first...'
      docker swarm leave --force || true
    fi
    
    docker swarm init --advertise-addr ${advertise_ip}
  "
  
  # Get join tokens
  local manager_token worker_token
  manager_token=$(ssh_to_node "$first_manager_hostname" "$first_manager_public_ip" "docker swarm join-token manager -q")
  worker_token=$(ssh_to_node "$first_manager_hostname" "$first_manager_public_ip" "docker swarm join-token worker -q")
  
  log "  Manager token: ${manager_token:0:20}..."
  log "  Worker token: ${worker_token:0:20}..."
  
  # Create overlay networks on the first manager
  log "Creating Docker overlay networks..."
  ssh_to_node "$first_manager_hostname" "$first_manager_public_ip" "
    docker network create --driver overlay --subnet=11.128.0.0/24 --gateway=11.128.0.1 --opt com.docker.network.driver.mtu=1300 --attachable traefik-internetwork 2>/dev/null || echo 'traefik-internetwork already exists'
    docker network create --driver overlay --subnet=11.129.0.0/24 --gateway=11.129.0.1 --opt com.docker.network.driver.mtu=1300 --attachable db-internetwork 2>/dev/null || echo 'db-internetwork already exists'
    docker network create --driver overlay --subnet=11.130.0.0/24 --gateway=11.130.0.1 --opt com.docker.network.driver.mtu=1300 --attachable vpn-internetwork 2>/dev/null || echo 'vpn-internetwork already exists'
  "
  
  # Join other nodes to the swarm
  for node in "${SWARM_NODES[@]}"; do
    IFS=':' read -r hostname role public_ip wg_ip <<< "$node"
    
    # Skip the first manager
    if [ "$hostname" = "$first_manager_hostname" ]; then
      continue
    fi
    
    local node_advertise_ip
    node_advertise_ip=$(detect_mesh_ip "$hostname" "$public_ip")
    
    if [ "$role" = "manager" ]; then
      log "  Joining $hostname as manager..."
      ssh_to_node "$hostname" "$public_ip" "
        if docker info 2>/dev/null | grep -q 'Swarm: active'; then
          docker swarm leave --force || true
        fi
        docker swarm join --token ${manager_token} ${advertise_ip}:2377
      "
    else
      log "  Joining $hostname as worker..."
      ssh_to_node "$hostname" "$public_ip" "
        if docker info 2>/dev/null | grep -q 'Swarm: active'; then
          docker swarm leave --force || true
        fi
        docker swarm join --token ${worker_token} ${advertise_ip}:2377
      "
    fi
  done
  
  # Display cluster status
  log "Docker Swarm cluster status:"
  ssh_to_node "$first_manager_hostname" "$first_manager_public_ip" "docker node ls"
  
  cat <<EOF

=========================================================================
SUCCESS: Docker Swarm cluster bootstrapped!
=========================================================================

First Manager: $first_manager_hostname
Advertise IP:  $advertise_ip

Join tokens (for adding more nodes later):
  Manager: docker swarm join --token $manager_token $advertise_ip:2377
  Worker:  docker swarm join --token $worker_token $advertise_ip:2377

Overlay networks created:
  - traefik-internetwork (11.128.0.0/24)
  - db-internetwork      (11.129.0.0/24)
  - vpn-internetwork     (11.130.0.0/24)

=========================================================================
EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
main() {
  log "=========================================="
  log "Docker Swarm Bootstrap Script"
  log "=========================================="
  
  # Validate node definitions
  validate_nodes
  
  # Check SSH credentials directory
  if [ ! -d "$SSH_CREDENTIALS_DIR" ]; then
    err "SSH credentials directory not found: $SSH_CREDENTIALS_DIR"
    err "Please create the directory and add credential files for each node."
    err "File format: .hostname (e.g., .swarm-manager-01)"
    exit 1
  fi
  
  # Initialize SSH known_hosts for secure host key verification
  initialize_known_hosts
  
  # Check SSH connectivity
  check_ssh_connectivity
  
  # Check Debian-based distro
  check_debian_distro
  
  if [ "$CHECK_ONLY" = true ]; then
    log "Check-only mode: All prerequisites verified. Exiting."
    exit 0
  fi
  
  # Run system updates
  log "Running system updates on all nodes..."
  run_system_update
  
  # Wireguard setup
  if [ "$SKIP_WIREGUARD" = false ]; then
    install_wireguard
    generate_wireguard_keys
    configure_wireguard
    verify_wireguard_connectivity
  else
    log "Skipping Wireguard setup (--skip-wireguard)"
  fi
  
  # UFW firewall setup
  if [ "$SKIP_UFW" = false ]; then
    configure_ufw
  else
    log "Skipping UFW setup (--skip-ufw)"
  fi
  
  # Docker installation
  if [ "$SKIP_DOCKER" = false ]; then
    install_docker_all_nodes
  else
    log "Skipping Docker installation (--skip-docker)"
  fi
  
  # Docker Swarm setup
  if [ "$SKIP_SWARM" = false ]; then
    setup_docker_swarm
  else
    log "Skipping Docker Swarm setup (--skip-swarm)"
  fi
  
  log "=========================================="
  log "Bootstrap completed successfully!"
  log "=========================================="
}

# Run main function
main "$@"
