#!/usr/bin/env bash
# install-docker-and-create-docker-user.sh
# Installs Docker (using Docker's convenience script), creates user "docker" if needed,
# adds that user to the system sudo/wheel group and to the docker group, and starts/enables Docker.
# Tested conceptually for Debian/Ubuntu, RHEL/CentOS/Fedora, Arch-like systems.
set -euo pipefail

# --- Configuration ---
TARGET_USER="docker"      # user to create / configure
DOCKER_INSTALL_URL="https://get.docker.com"
SWARM_MODE="bootstrap"    # bootstrap | join-manager | join-worker | skip
SWARM_JOIN_TOKEN=""
SWARM_MANAGER_IP=""
# ----------------------

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --mode <MODE>           Swarm mode: bootstrap (default), join-manager, join-worker, skip
  --token <TOKEN>         Join token (required for join-manager and join-worker modes)
  --manager-ip <IP>       Manager IP address (required for join-manager and join-worker modes)
  --user <USERNAME>       Target user to create (default: docker)
  -h, --help              Show this help message

Examples:
  # Bootstrap a new swarm (first manager node)
  $0 --mode bootstrap

  # Join as a manager
  $0 --mode join-manager --token SWMTKN-xxx --manager-ip 10.0.0.1:2377

  # Join as a worker
  $0 --mode join-worker --token SWMTKN-yyy --manager-ip 10.0.0.1:2377

  # Skip swarm setup
  $0 --mode skip
EOF
  exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      SWARM_MODE="$2"
      shift 2
      ;;
    --token)
      SWARM_JOIN_TOKEN="$2"
      shift 2
      ;;
    --manager-ip)
      SWARM_MANAGER_IP="$2"
      shift 2
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

# Validate swarm mode
case "$SWARM_MODE" in
  bootstrap|skip) ;;
  join-manager|join-worker)
    if [ -z "$SWARM_JOIN_TOKEN" ] || [ -z "$SWARM_MANAGER_IP" ]; then
      err "For mode '$SWARM_MODE', both --token and --manager-ip are required"
      exit 1
    fi
    ;;
  *)
    err "Invalid swarm mode: $SWARM_MODE. Must be: bootstrap, join-manager, join-worker, or skip"
    exit 1
    ;;
esac

# Must be run as root
if [ "$EUID" -ne 0 ]; then
  err "This script must be run as root. Use: sudo $0"
  exit 1
fi

log "Detecting distribution..."
if [ -f /etc/os-release ]; then
  set +u
  . /etc/os-release
  set -u
  DISTRO_ID="${ID:-unknown}"
  DISTRO_ID="${DISTRO_ID,,}"
  DISTRO_PRETTY="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
else
  DISTRO_ID="unknown"
  DISTRO_PRETTY="Unknown Linux"
fi
log "Detected: $DISTRO_PRETTY (ID=$DISTRO_ID)"

# Install common prerequisites (curl, ca-certificates, lsb-release, gnupg) where relevant
install_prereqs() {
  case "$DISTRO_ID" in
    ubuntu|debian)
      apt-get update -y
      apt-get install -y --no-install-recommends curl ca-certificates gnupg lsb-release
      ;;
    centos|rhel|rocky|almalinux)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates gnupg2 lsb-release
      else
        yum install -y curl ca-certificates gnupg2 redhat-lsb-core
      fi
      ;;
    fedora)
      dnf install -y curl ca-certificates gnupg2 lsb-release
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm curl ca-certificates gnupg lsb-release
      ;;
    *)
      log "Unknown/unsupported distro ($DISTRO_ID). Attempting to continue — the Docker convenience script handles many distros."
      # still try to install curl if missing
      if ! command -v curl >/dev/null 2>&1; then
        err "curl not found. Please install curl and re-run this script."
        exit 1
      fi
      ;;
  esac
}

install_prereqs

log "Downloading and running Docker convenience install script from $DOCKER_INSTALL_URL"
# run the official convenience script
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$DOCKER_INSTALL_URL" | sh
else
  err "curl not available; cannot download $DOCKER_INSTALL_URL"
  exit 1
fi

log "Ensuring 'docker' group exists"
if ! getent group docker >/dev/null 2>&1; then
  groupadd docker
  log "Created docker group"
else
  log "docker group already exists"
fi

log "Creating target user '$TARGET_USER' if it does not exist"
if id -u "$TARGET_USER" >/dev/null 2>&1; then
  log "User '$TARGET_USER' already exists"
else
  useradd -m -s /bin/bash -N "$TARGET_USER"
  log "Created user '$TARGET_USER'"
fi

# Add the user to the docker group
usermod -aG docker "$TARGET_USER"
log "Added $TARGET_USER to docker group"

# Add the user to sudo/wheel admin group if present
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$TARGET_USER"
  log "Added $TARGET_USER to 'sudo' group"
elif getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "$TARGET_USER"
  log "Added $TARGET_USER to 'wheel' group"
else
  log "No 'sudo' or 'wheel' group found on this system. Skipping admin group addition."
fi

# Enable & start Docker service if systemd is present
if command -v systemctl >/dev/null 2>&1; then
  log "Enabling and starting docker service"
  systemctl enable --now docker
  log "docker service enabled and started (systemctl)"
else
  log "systemctl not found — please enable/start docker manually (non-systemd system)"
fi

# --- Detect mesh interface IP ---
detect_mesh_ip() {
  local iface ip
  for iface in tailscale0 wt0 wg0 nebula0 tun0; do
    if ip link show "$iface" >/dev/null 2>&1; then
      ip=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
      if [ -n "$ip" ]; then
        echo "$ip"
        return 0
      fi
    fi
  done
  # fallback: default route interface
  ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
  echo "$ip"
}

# --- Docker Swarm Setup ---
if [ "$SWARM_MODE" = "skip" ]; then
  log "Skipping Docker Swarm setup (--mode skip)"
else
  case "$SWARM_MODE" in
    bootstrap)
      ADVERTISE_IP=$(detect_mesh_ip)
      if [ -z "$ADVERTISE_IP" ]; then
        err "Failed to detect advertise IP."
        exit 1
      fi
      
      log "Using advertise IP: $ADVERTISE_IP"
      
      if docker info 2>/dev/null | grep -q 'Swarm: active'; then
        warn "Docker Swarm is already initialized. Reinitializing..."
        docker swarm leave --force || true
      fi
      
      log "Initializing Docker Swarm as bootstrap manager..."
      docker swarm init --advertise-addr "$ADVERTISE_IP"
      
      # Display join tokens
      MANAGER_TOKEN=$(docker swarm join-token manager -q)
      WORKER_TOKEN=$(docker swarm join-token worker -q)

      log "Initializing Docker user-defined ingress network..."
      docker network create --driver overlay --subnet=10.128.0.0/24 --gateway=10.128.0.1 --opt com.docker.network.driver.mtu=1200 --opt com.docker.network.endpoint.ifname=eth0 --attachable traefik-internetwork
      docker network create --driver overlay --subnet=10.129.0.0/24 --gateway=10.129.0.1 --opt com.docker.network.driver.mtu=1200 --opt com.docker.network.endpoint.ifname=eth0 --attachable db-internetwork
      docker network create --driver overlay --subnet=10.130.0.0/24 --gateway=10.130.0.1 --opt com.docker.network.driver.mtu=1200 --opt com.docker.network.endpoint.ifname=eth0 --attachable vpn-internetwork
      cat <<EOF

SUCCESS: Docker Swarm bootstrapped!
  Advertise IP: $ADVERTISE_IP
  
  Join tokens:
    Manager: docker swarm join --token $MANAGER_TOKEN $ADVERTISE_IP:2377
    Worker:  docker swarm join --token $WORKER_TOKEN $ADVERTISE_IP:2377

EOF
      ;;
      
    join-manager)
      log "Joining Docker Swarm as manager..."
      if docker info 2>/dev/null | grep -q 'Swarm: active'; then
        warn "This node is already in a swarm. Leaving first..."
        docker swarm leave --force || true
      fi
      
      docker swarm join --token "$SWARM_JOIN_TOKEN" "$SWARM_MANAGER_IP"
      log "Successfully joined swarm as manager"
      ;;
      
    join-worker)
      log "Joining Docker Swarm as worker..."
      if docker info 2>/dev/null | grep -q 'Swarm: active'; then
        warn "This node is already in a swarm. Leaving first..."
        docker swarm leave --force || true
      fi
      
      docker swarm join --token "$SWARM_JOIN_TOKEN" "$SWARM_MANAGER_IP"
      log "Successfully joined swarm as worker"
      ;;
  esac
fi

cat <<EOF

SUCCESS:
1. Docker is installed and running
2. User '$TARGET_USER' is configured with Docker access
3. Swarm mode: $SWARM_MODE

Important notes / next steps:
  * Docker's convenience script (used here) is provided by Docker, Inc. and is convenient for provisioning and dev environments; for production or stricter control, follow distro-specific repository instructions. See: https://get.docker.com/ and Docker docs.
  * The 'docker' group grants effective root privileges for Docker management. Be careful which users you add to this group. See Docker post-install docs for security notes.
  * To use Docker as the '$TARGET_USER' immediately without logging out/in, you can:
      - switch to the user in a new session:  su - $TARGET_USER
      - or run:                         newgrp docker    # starts a subshell with docker group active
    However many programs and services require a full re-login or new PAM session for group changes to be applied.
  * Quick test (as root or after switching to $TARGET_USER):
      su - $TARGET_USER -c "docker run --rm hello-world"

Citations:
  * Docker convenience install: https://get.docker.com/
  * Docker post-install (create docker group, add user): see Docker docs (Linux post-installation steps).
EOF
