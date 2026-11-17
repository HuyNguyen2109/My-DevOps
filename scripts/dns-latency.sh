#!/usr/bin/env bash
# =============================================================================
# dns-latency.sh — Measure DNS latency of well-known public resolvers
# =============================================================================
# Runs on: any Linux host with `dig` and `timeout` available
#
# Sends a real A-record query to each resolver (not an ICMP ping) and prints
# a table sorted fastest-first. Every resolver is probed once per sample round
# and all resolvers run in parallel, so the measurement phase is bounded by
# SAMPLES × DIG_TIMEOUT and guarded by DEADLINE_SECS (30 s).
#
# Prerequisites:
#   dig      — Debian/Ubuntu: dnsutils | RHEL/Fedora/openSUSE: bind-utils
#              Arch: bind
#   timeout  — GNU coreutils
#
# Notes:
#   - IPv4 resolvers only (no IPv6, DoH, or DoT) so the script runs anywhere.
#   - "LOSS" means no DNS reply within DIG_TIMEOUT; those samples are excluded
#     from the latency statistics.
#   - NextDNS serves per-profile IPs; 45.90.28.0 and 45.90.30.0 are its
#     public anycast addresses (a default profile answers for them).
# =============================================================================

set -uo pipefail

# =============================================================================
# CONFIG — defaults can be overridden via environment variables
# =============================================================================
SAMPLES="${SAMPLES:-3}"          # queries per resolver, all resolvers in parallel
DIG_TIMEOUT="${DIG_TIMEOUT:-2}"  # seconds per query before it counts as loss
DEADLINE_SECS=30                 # hard cap for the whole measurement phase
QUERY_NAME="${QUERY_NAME:-example.com}"

# Format: "Display name|IPv4 address"
RESOLVERS=(
  "Cloudflare|1.1.1.1"
  "Google|8.8.8.8"
  "Quad9|9.9.9.9"
  "OpenDNS|208.67.222.222"
  "AdGuard|94.140.14.14"
  "NextDNS|45.90.28.0"
  "Control D|76.76.2.0"
  "Mullvad|194.242.2.2"
  "DNS0.eu|193.110.81.0"
  "CleanBrowsing|185.228.168.9"
  "Comodo|8.26.56.26"
  "Level3|4.2.2.2"
  "Verizon|64.6.64.6"
  "Yandex|77.88.8.8"
  "AliDNS|223.5.5.5"
  "DNSPod|119.29.29.29"
  "114DNS|114.114.114.114"
  "Baidu|180.76.76.76"
)

die() {
  echo "Error: $*" >&2
  exit 1
}

check_dependencies() {
  command -v dig >/dev/null 2>&1 ||
    die "dig not found — install dnsutils (Debian/Ubuntu), bind-utils (RHEL/Fedora/openSUSE), or bind (Arch)."
  command -v timeout >/dev/null 2>&1 ||
    die "timeout not found — install GNU coreutils."
}

validate_config() {
  if ! [[ $SAMPLES =~ ^[0-9]+$ ]] || ! (( SAMPLES > 0 )); then
    die "SAMPLES must be a positive integer (got '$SAMPLES')."
  fi
  if ! [[ $DIG_TIMEOUT =~ ^[0-9]+$ ]] || ! (( DIG_TIMEOUT > 0 )); then
    die "DIG_TIMEOUT must be a positive integer (got '$DIG_TIMEOUT')."
  fi
  (( DIG_TIMEOUT + 1 <= DEADLINE_SECS )) ||
    die "DIG_TIMEOUT must leave room within the ${DEADLINE_SECS}s deadline."
  [[ -n $QUERY_NAME ]] || die "QUERY_NAME must not be empty."
}

main() {
  check_dependencies
  validate_config

  TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t dns-latency) ||
    die "cannot create a temporary directory"
  trap 'rm -rf "$TMP_DIR"' EXIT INT TERM HUP

  local total=${#RESOLVERS[@]}
  echo "Measuring ${total} resolvers × ${SAMPLES} samples (max ${DEADLINE_SECS}s)..." >&2

  local start=$SECONDS
  local rounds_run=0
  local deadline_hit=0
  local r i entry ip
  local -a pids

  for (( r = 1; r <= SAMPLES; r++ )); do
    # Keep the whole measurement phase within the deadline.
    if (( SECONDS - start + DIG_TIMEOUT + 1 > DEADLINE_SECS )); then
      deadline_hit=1
      break
    fi

    pids=()
    for i in "${!RESOLVERS[@]}"; do
      ip=${RESOLVERS[$i]#*|}
      timeout $(( DIG_TIMEOUT + 1 )) \
        dig +time="$DIG_TIMEOUT" +tries=1 +noall +comments +stats +answer \
        @"$ip" "$QUERY_NAME" A >"$TMP_DIR/$r.$i" 2>&1 &
      pids+=("$!")
    done
    wait "${pids[@]}" 2>/dev/null
    rounds_run=$r
  done

  # Aggregate: sum in integer milliseconds, track min/max and losses.
  local -a sum min max replies
  for i in "${!RESOLVERS[@]}"; do
    sum[i]=0
    min[i]=0
    max[i]=0
    replies[i]=0
  done

  local ms
  for i in "${!RESOLVERS[@]}"; do
    for (( r = 1; r <= rounds_run; r++ )); do
      [[ -f $TMP_DIR/$r.$i ]] || continue
      ms=$(awk '/;; Query time:/ {print $4; exit}' "$TMP_DIR/$r.$i")
      [[ $ms =~ ^[0-9]+$ ]] || continue

      sum[i]=$(( sum[i] + ms ))
      replies[i]=$(( replies[i] + 1 ))
      if (( replies[i] == 1 || ms < min[i] )); then min[i]=$ms; fi
      if (( ms > max[i] )); then max[i]=$ms; fi
    done
  done

  # Build sortable rows; unreachable resolvers sort last.
  local name avg_tenths loss
  : >"$TMP_DIR/rows"
  for i in "${!RESOLVERS[@]}"; do
    entry=${RESOLVERS[$i]}
    name=${entry%%|*}
    ip=${entry#*|}
    loss=$(( (rounds_run - replies[i]) * 100 / rounds_run ))

    if (( replies[i] > 0 )); then
      avg_tenths=$(( (sum[i] * 10 + replies[i] / 2) / replies[i] ))
      printf '%06d|%s|%s|%d.%d|%d|%d|%d\n' \
        "$avg_tenths" "$name" "$ip" \
        "$(( avg_tenths / 10 ))" "$(( avg_tenths % 10 ))" \
        "${min[i]}" "${max[i]}" "$loss" >>"$TMP_DIR/rows"
    else
      printf '%06d|%s|%s|timeout|-|-|%d\n' \
        999999 "$name" "$ip" "$loss" >>"$TMP_DIR/rows"
    fi
  done
  sort -t'|' -k1,1n "$TMP_DIR/rows" >"$TMP_DIR/sorted"

  # Column widths.
  local name_w=8 rank=0
  for entry in "${RESOLVERS[@]}"; do
    name=${entry%%|*}
    (( ${#name} > name_w )) && name_w=${#name}
  done

  echo
  printf '%2s  %-*s  %-15s  %8s  %5s  %5s  %5s\n' \
    "#" "$name_w" "RESOLVER" "ADDRESS" "AVG(ms)" "MIN" "MAX" "LOSS"

  local row_name row_ip row_avg row_min row_max row_loss
  while IFS='|' read -r _ row_name row_ip row_avg row_min row_max row_loss; do
    rank=$(( rank + 1 ))
    printf '%2d  %-*s  %-15s  %8s  %5s  %5s  %4s%%\n' \
      "$rank" "$name_w" "$row_name" "$row_ip" \
      "$row_avg" "$row_min" "$row_max" "$row_loss"
  done <"$TMP_DIR/sorted"

  echo
  printf 'Query: %s A | samples: %d per resolver | timeout: %ss/query\n' \
    "$QUERY_NAME" "$rounds_run" "$DIG_TIMEOUT"
  if (( deadline_hit )); then
    printf 'Measurement stopped at the %ss deadline — partial samples used.\n' "$DEADLINE_SECS"
  fi
  printf 'Measurement time: %ss (limit: %ss)\n' "$(( SECONDS - start ))" "$DEADLINE_SECS"
}

main "$@"
