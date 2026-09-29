#!/usr/bin/env bash
# =============================================================================
# netbird-connect.sh — Connect homelab nodes to the self-hosted NetBird mesh
# =============================================================================
# Runs on: devbox / any machine with SSH access to the homelab
#
# Targets:
#   talos-01       (192.168.1.12)  — bare-metal k8s node
#   talos-02       (192.168.1.13)  — bare-metal k8s node
#   talos-cloud-00 (14.225.220.145) — cloud VM (reached via ProxyJump)
#
# Prerequisites:
#   ~/ssh-keys/homelab-linux   — SSH private key (talos-01, talos-02)
#   ~/ssh-keys/oracle          — SSH private key (talos-cloud-00)
#   ubuntu sudo NOPASSWD       — required on talos-01 / talos-02
#
# Known issue:
#   If the NetBird client on talos-cloud-00 is in a broken state, it can
#   hijack return SSH traffic through its WireGuard interface, making the
#   host unreachable via SSH.  Recovery requires Oracle Cloud web console:
#
#     systemctl stop netbird
#     ip link delete wt0 2>/dev/null
#     ip route flush table 220 2>/dev/null
#     # Then re-run this script
# =============================================================================

set -uo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
MANAGEMENT_URL="https://netbird.mcb-homelab.com"
SETUP_KEY="${NETBIRD_SETUP_KEY:-E63BB49B-0643-4EBE-8DA7-AF1458C84AD5}"

SSH_TIMEOUT=15
HOMELAB_KEY="${HOME}/ssh-keys/homelab-linux"
ORACLE_KEY="${HOME}/ssh-keys/oracle"

# =============================================================================
# COLORS
# =============================================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi
CHECK="✓"; CROSS="✗"; WARN="⚠"

# =============================================================================
# SSH BASE OPTIONS (used by all ssh commands)
# =============================================================================
SSH_BASE=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
  -o ConnectTimeout="${SSH_TIMEOUT}"
  -T
)

# =============================================================================
# PER-HOST SETUP (runs in background subshell)
# =============================================================================
setup_netbird() {
  local name="$1"
  shift
  # Remaining args are the ssh command array (ssh, options, user@host, etc.)

  local msg=""

  # ── Check if daemon is running ──────────────────────────────────────────
  if ! timeout "${SSH_TIMEOUT}" "$@" "systemctl is-active --quiet netbird" 2>/dev/null; then
    msg="netbird service not active or SSH failed"
    printf '%s\n' "${msg}"
    return 1
  fi

  # ── Check if already connected to correct management server ─────────────
  local status_output
  status_output="$(timeout "${SSH_TIMEOUT}" "$@" "sudo netbird status 2>&1" 2>/dev/null || true)"

  if echo "${status_output}" | grep -q "Management: Connected"; then
    if echo "${status_output}" | grep -q "FQDN:.*netbird\.selfhosted"; then
      msg="already connected to self-hosted management"
      printf '%s\n' "${msg}"
      return 0
    fi
  fi

  # ── Disconnect from current management server and reconnect ─────────────
  local up_output
  up_output="$(timeout "${SSH_TIMEOUT}" "$@" "sudo netbird down 2>&1 && sleep 2 && sudo netbird up --management-url ${MANAGEMENT_URL} --setup-key ${SETUP_KEY} 2>&1" 2>/dev/null || true)"

  if echo "${up_output}" | grep -qE "Connected|Already connected"; then
    msg="connected to ${MANAGEMENT_URL}"
  else
    msg="failed: ${up_output:-SSH timeout or error}"
    printf '%s\n' "${msg}"
    return 1
  fi

  printf '%s\n' "${msg}"
  return 0
}

# =============================================================================
# MAIN
# =============================================================================
echo -e "\n${CYAN}${BOLD}══ NetBird Connect ══${RESET}"
echo -e "  Management: ${MANAGEMENT_URL}\n"

declare -A PIDS
declare -A RESULTS
declare -A MESSAGES
declare -A TMPFILES

# ── Define hosts with their full SSH command arrays ────────────────────────
# Each entry: "name display_ip ssh_args...@"
# We separate by a unique delimiter (@) to build the arrays.
#
# talos-01 — direct SSH
setup_01_args=(ssh "${SSH_BASE[@]}" -i "${HOMELAB_KEY}" ubuntu@192.168.1.12)
# talos-02 — direct SSH
setup_02_args=(ssh "${SSH_BASE[@]}" -i "${HOMELAB_KEY}" ubuntu@192.168.1.13)
# talos-cloud-00 — via ProxyJump through talos-01
setup_cloud_args=(ssh "${SSH_BASE[@]}" -i "${ORACLE_KEY}" -o ProxyJump="ubuntu@192.168.1.12" -o IdentityFile="${HOMELAB_KEY}" root@14.225.220.145)

# ── Launch parallel setup ─────────────────────────────────────────────────
run_host() {
  local name="$1"
  shift
  setup_netbird "${name}" "$@"
}

# talos-01
tmpfile="$(mktemp)"
( run_host "talos-01" "${setup_01_args[@]}" > "${tmpfile}" 2>&1 ) &
PIDS["talos-01"]=$!
TMPFILES["talos-01"]="${tmpfile}"
echo -e "  ${YELLOW}${WARN}${RESET}  $(printf '%-16s' "talos-01")  connecting..."

# talos-02
tmpfile="$(mktemp)"
( run_host "talos-02" "${setup_02_args[@]}" > "${tmpfile}" 2>&1 ) &
PIDS["talos-02"]=$!
TMPFILES["talos-02"]="${tmpfile}"
echo -e "  ${YELLOW}${WARN}${RESET}  $(printf '%-16s' "talos-02")  connecting..."

# talos-cloud-00
tmpfile="$(mktemp)"
( run_host "talos-cloud-00" "${setup_cloud_args[@]}" > "${tmpfile}" 2>&1 ) &
PIDS["talos-cloud-00"]=$!
TMPFILES["talos-cloud-00"]="${tmpfile}"
echo -e "  ${YELLOW}${WARN}${RESET}  $(printf '%-16s' "talos-cloud-00")  connecting..."

# ── Wait and collect results ──────────────────────────────────────────────
for name in talos-01 talos-02 talos-cloud-00; do
  exit_code=1
  wait "${PIDS[${name}]}" 2>/dev/null && exit_code=0 || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    RESULTS["${name}"]="ok"
  else
    RESULTS["${name}"]="fail"
  fi

  MESSAGES["${name}"]="$(cat "${TMPFILES[${name}]}" 2>/dev/null || echo "unknown error")"
  rm -f "${TMPFILES[${name}]}"
done

# ── Summary table ─────────────────────────────────────────────────────────
echo -e "\n  ${BOLD}$(printf '%-16s' 'Host')  Result${RESET}"
echo    "  ────────────────────────────────────"
for name in talos-01 talos-02 talos-cloud-00; do
  if [[ "${RESULTS[${name}]:-fail}" == "ok" ]]; then
    echo -e "  ${GREEN}${CHECK}${RESET}  $(printf '%-16s' "${name}")  ${GREEN}${MESSAGES[${name}]}${RESET}"
  else
    echo -e "  ${RED}${CROSS}${RESET}  $(printf '%-16s' "${name}")  ${RED}${MESSAGES[${name}]}${RESET}"
  fi
done

echo ""
