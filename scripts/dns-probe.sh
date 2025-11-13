#!/bin/bash
#
# DNS Probe Script - Parallel DNS Resolution Testing
#
# Description:
#   Tests DNS resolution from multiple sources in parallel, logging start time,
#   resolution time, and duration for each probe method. Designed for long-running
#   tests (1-3 hours or more) to detect when DNS records become available.
#
# Compatibility:
#   - macOS (tested on macOS 11+)
#   - RHEL 9/10 (and compatible distributions)
#   - Requires: dig (bind-utils), curl
#   - Optional: column (for formatted output)
#
# Probe Methods (all run in parallel):
#   1. Default OS DNS configuration
#   2. Cloudflare (1.1.1.1)
#   3. Quad9 (9.9.9.9)
#   4. Google (8.8.8.8)
#   5. DNS over HTTPS (DoH) via Cloudflare
#
# Installation:
#   macOS:  brew install bind
#   RHEL:   sudo dnf install bind-utils curl
#
# Author: Generated for DNS propagation testing
# License: MIT

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DOMAIN=""
SLEEP_INTERVAL=5  # Increased for long-running tests
MAX_ATTEMPTS=0    # 0 means unlimited (suitable for 1-3 hour runs)
OUTPUT_FILE=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Help function
show_help() {
    cat << EOF
DNS Probe Script - Repeatedly probe DNS until records are found (runs in parallel)

Usage: $0 [OPTIONS] <domain>

Arguments:
    domain              Domain name to probe (e.g., example.com)

Options:
    -h, --help         Show this help message
    -i, --interval N   Sleep interval between probes in seconds (default: 5)
    -m, --max N        Maximum number of attempts per probe (default: unlimited)
    -o, --output FILE  Output file for results (default: dns-probe-results-TIMESTAMP.csv)

Examples:
    $0 example.com
    $0 -i 2 -m 1000 test.example.com
    $0 --interval 10 --output results.csv new-domain.com

Notes:
    - All probes run in parallel
    - Default settings support long-running tests (1-3 hours)
    - Results are logged with timestamps to output file
    - Compatible with macOS and RHEL 9/10

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--interval)
            SLEEP_INTERVAL="$2"
            shift 2
            ;;
        -m|--max)
            MAX_ATTEMPTS="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}" >&2
            show_help
            exit 1
            ;;
        *)
            DOMAIN="$1"
            shift
            ;;
    esac
done

# Validate domain argument
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}Error: Domain name is required${NC}" >&2
    show_help
    exit 1
fi

# Set default output file if not specified
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="dns-probe-results-${TIMESTAMP}.csv"
fi

# Check for required tools
check_tools() {
    local missing_tools=()
    
    if ! command -v dig &> /dev/null; then
        missing_tools+=("dig (dnsutils/bind-tools)")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools:${NC}"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "Installation instructions:"
        echo "  macOS:  brew install bind"
        echo "  RHEL:   sudo dnf install bind-utils curl"
        exit 1
    fi
}

# Initialize output file with header
init_output_file() {
    echo "Probe Method,Start Time,Start Timestamp,Resolution Time,Resolution Timestamp,Duration (seconds),Attempts,Result,Status" > "$OUTPUT_FILE"
    echo -e "${GREEN}Output file created: $OUTPUT_FILE${NC}"
}

# Log result to output file (thread-safe append)
log_result() {
    local method="$1"
    local start_time="$2"
    local start_ts="$3"
    local end_time="$4"
    local end_ts="$5"
    local duration="$6"
    local attempts="$7"
    local result="$8"
    local status="$9"
    
    # Escape commas and quotes in result for CSV
    result=$(echo "$result" | tr '\n' ' ' | tr ',' ';')
    
    # Atomic append to file
    echo "$method,$start_time,$start_ts,$end_time,$end_ts,$duration,$attempts,\"$result\",$status" >> "$OUTPUT_FILE"
}

# Probe DNS using default OS configuration (runs as background job)
probe_default() {
    local method="Default OS DNS"
    local attempt=0
    local start_ts=$(date +%s)
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${BLUE}[1/5] Probing with default OS DNS configuration...${NC}"
    
    while true; do
        attempt=$((attempt + 1))
        
        if [[ $MAX_ATTEMPTS -gt 0 && $attempt -gt $MAX_ATTEMPTS ]]; then
            local end_ts=$(date +%s)
            local end_time=$(date '+%Y-%m-%d %H:%M:%S')
            local duration=$((end_ts - start_ts))
            echo -e "${RED}  ✗ Max attempts ($MAX_ATTEMPTS) reached${NC}"
            log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "No record found" "TIMEOUT"
            return 1
        fi
        
        if [[ $((attempt % 10)) -eq 1 ]]; then
            echo -e "  ${YELLOW}[Default OS DNS] Attempt $attempt...${NC}"
        fi
        
        if result=$(dig +short "$DOMAIN" 2>&1) && [[ -n "$result" ]]; then
            local end_ts=$(date +%s)
            local end_time=$(date '+%Y-%m-%d %H:%M:%S')
            local duration=$((end_ts - start_ts))
            echo -e "${GREEN}  ✓ [Default OS DNS] DNS record found after ${duration}s (${attempt} attempts)${NC}"
            echo -e "    Time: $end_time"
            echo "    Result: $result"
            log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "$result" "SUCCESS"
            return 0
        else
            sleep "$SLEEP_INTERVAL"
        fi
    done
}

# Probe DNS using specific server (runs as background job)
probe_with_server() {
    local server="$1"
    local method="$2"
    local attempt=0
    local start_ts=$(date +%s)
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${BLUE}Probing with DNS server $server ($method)...${NC}"
    
    while true; do
        attempt=$((attempt + 1))
        
        if [[ $MAX_ATTEMPTS -gt 0 && $attempt -gt $MAX_ATTEMPTS ]]; then
            local end_ts=$(date +%s)
            local end_time=$(date '+%Y-%m-%d %H:%M:%S')
            local duration=$((end_ts - start_ts))
            echo -e "${RED}  ✗ [$method] Max attempts ($MAX_ATTEMPTS) reached${NC}"
            log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "No record found" "TIMEOUT"
            return 1
        fi
        
        if [[ $((attempt % 10)) -eq 1 ]]; then
            echo -e "  ${YELLOW}[$method] Attempt $attempt...${NC}"
        fi
        
        if result=$(dig +short "@$server" "$DOMAIN" 2>&1) && [[ -n "$result" ]]; then
            local end_ts=$(date +%s)
            local end_time=$(date '+%Y-%m-%d %H:%M:%S')
            local duration=$((end_ts - start_ts))
            echo -e "${GREEN}  ✓ [$method] DNS record found after ${duration}s (${attempt} attempts)${NC}"
            echo -e "    Time: $end_time"
            echo "    Result: $result"
            log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "$result" "SUCCESS"
            return 0
        else
            sleep "$SLEEP_INTERVAL"
        fi
    done
}

# Probe DNS over HTTPS (DoH) using Cloudflare (runs as background job)
probe_doh() {
    local method="DNS over HTTPS (1.1.1.1)"
    local attempt=0
    local start_ts=$(date +%s)
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${BLUE}Probing with DNS over HTTPS (1.1.1.1)...${NC}"
    
    while true; do
        attempt=$((attempt + 1))
        
        if [[ $MAX_ATTEMPTS -gt 0 && $attempt -gt $MAX_ATTEMPTS ]]; then
            local end_ts=$(date +%s)
            local end_time=$(date '+%Y-%m-%d %H:%M:%S')
            local duration=$((end_ts - start_ts))
            echo -e "${RED}  ✗ [DoH] Max attempts ($MAX_ATTEMPTS) reached${NC}"
            log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "No record found" "TIMEOUT"
            return 1
        fi
        
        if [[ $((attempt % 10)) -eq 1 ]]; then
            echo -e "  ${YELLOW}[DoH] Attempt $attempt...${NC}"
        fi
        
        # Use Cloudflare's DoH endpoint
        if result=$(curl -s -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" 2>&1); then
            
            # Check if we got a valid response with answers
            if echo "$result" | grep -q '"Answer"' && \
               ! echo "$result" | grep -q '"Answer":\[\]'; then
                local end_ts=$(date +%s)
                local end_time=$(date '+%Y-%m-%d %H:%M:%S')
                local duration=$((end_ts - start_ts))
                
                # Extract IP addresses from JSON response
                local ips=$(echo "$result" | grep -o '"data":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
                
                echo -e "${GREEN}  ✓ [DoH] DNS record found after ${duration}s (${attempt} attempts)${NC}"
                echo -e "    Time: $end_time"
                echo "    Result: $ips"
                log_result "$method" "$start_time" "$start_ts" "$end_time" "$end_ts" "$duration" "$attempt" "$ips" "SUCCESS"
                return 0
            else
                sleep "$SLEEP_INTERVAL"
            fi
        else
            sleep "$SLEEP_INTERVAL"
        fi
    done
}

# Main execution
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    DNS Probe Script - Parallel Testing                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Domain: $DOMAIN"
    echo "Interval: ${SLEEP_INTERVAL}s between probes"
    if [[ $MAX_ATTEMPTS -gt 0 ]]; then
        echo "Max attempts per probe: $MAX_ATTEMPTS"
        echo "Estimated max runtime: $((MAX_ATTEMPTS * SLEEP_INTERVAL / 60)) minutes"
    else
        echo "Max attempts per probe: unlimited"
        echo "Note: Suitable for long-running tests (1-3 hours or more)"
    fi
    echo ""
    echo "Starting DNS probes at: $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    check_tools
    init_output_file
    
    echo ""
    echo -e "${BLUE}Launching all probes in parallel...${NC}"
    echo ""
    
    # Array to track background job PIDs
    declare -a pids=()
    
    # Launch all probes as background processes
    probe_default &
    pids+=($!)
    
    probe_with_server "1.1.1.1" "Cloudflare 1.1.1.1" &
    pids+=($!)
    
    probe_with_server "9.9.9.9" "Quad9 9.9.9.9" &
    pids+=($!)
    
    probe_with_server "8.8.8.8" "Google 8.8.8.8" &
    pids+=($!)
    
    probe_doh &
    pids+=($!)
    
    echo -e "${BLUE}All probes running in parallel (PIDs: ${pids[*]})${NC}"
    echo -e "${YELLOW}Waiting for all probes to complete...${NC}"
    echo -e "${YELLOW}(This may take 1-3 hours or until DNS records are found)${NC}"
    echo ""
    
    # Wait for all background jobs to complete
    local failed=0
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            echo -e "${GREEN}Process $pid completed successfully${NC}"
        else
            echo -e "${RED}Process $pid failed or timed out${NC}"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}All DNS probes completed!${NC}"
    echo "Finished at: $(date)"
    echo ""
    echo -e "${GREEN}Results saved to: $OUTPUT_FILE${NC}"
    
    if [[ -f "$OUTPUT_FILE" ]]; then
        echo ""
        echo "Summary:"
        echo "--------"
        column -t -s',' "$OUTPUT_FILE" | head -n 10
        
        if [[ $(wc -l < "$OUTPUT_FILE") -gt 10 ]]; then
            echo "... (see $OUTPUT_FILE for complete results)"
        fi
    fi
    
    if [[ $failed -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Warning: $failed probe(s) did not complete successfully${NC}"
        return 1
    fi
    
    return 0
}

# Trap to handle interrupts and cleanup
cleanup() {
    echo ""
    echo -e "${YELLOW}Interrupt received. Cleaning up background processes...${NC}"
    # Kill all child processes
    jobs -p | xargs kill 2>/dev/null
    echo -e "${GREEN}Cleanup complete. Partial results saved to: $OUTPUT_FILE${NC}"
    exit 130
}

trap cleanup INT TERM

# Run main function
main

