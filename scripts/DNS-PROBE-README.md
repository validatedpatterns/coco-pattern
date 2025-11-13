# DNS Probe Script - Usage Guide

## Overview

The `dns-probe.sh` script performs parallel DNS resolution testing from multiple sources, logging start time, resolution time, and duration for each probe method. It's designed for long-running tests (1-3 hours or more) to detect when DNS records become available.

## Features

- ✅ **Parallel Execution** - All 5 probe methods run simultaneously
- ✅ **Comprehensive Logging** - CSV output with timestamps and metrics
- ✅ **Long-Running Support** - Designed for 1-3 hour test periods
- ✅ **Cross-Platform** - Works on macOS and RHEL 9/10
- ✅ **Multiple DNS Methods** - Tests 5 different DNS resolution paths
- ✅ **Graceful Interruption** - Handles Ctrl+C cleanly with partial results

## Probe Methods

The script tests DNS resolution using 5 different methods (all running in parallel):

1. **Default OS DNS** - Uses your system's configured DNS servers
2. **Cloudflare (1.1.1.1)** - Direct query to Cloudflare DNS
3. **Quad9 (9.9.9.9)** - Direct query to Quad9 DNS
4. **Google (8.8.8.8)** - Direct query to Google DNS
5. **DNS over HTTPS (DoH)** - Secure HTTPS query to Cloudflare

## Requirements

### macOS
```bash
# Install dig (if not already available)
brew install bind

# curl is typically pre-installed
```

### RHEL 9/10
```bash
# Install required packages
sudo dnf install bind-utils curl

# Optional: for better output formatting
sudo dnf install util-linux  # provides 'column' command
```

### Verification
```bash
# Verify required tools are installed
which dig
which curl
```

## Installation

```bash
# Make the script executable
chmod +x dns-probe.sh
```

## Usage

### Basic Usage

```bash
# Test a domain with default settings (5-second intervals, unlimited attempts)
./dns-probe.sh example.com
```

### Custom Interval

```bash
# Use 2-second intervals between probes
./dns-probe.sh -i 2 example.com

# Use 10-second intervals (more suitable for 3-hour tests)
./dns-probe.sh -i 10 example.com
```

### Limited Attempts

```bash
# Limit to 720 attempts (1 hour with 5-second intervals)
./dns-probe.sh -i 5 -m 720 example.com

# Limit to 1080 attempts (1.5 hours with 5-second intervals)
./dns-probe.sh -i 5 -m 1080 example.com

# Limit to 2160 attempts (3 hours with 5-second intervals)
./dns-probe.sh -i 5 -m 2160 example.com
```

### Custom Output File

```bash
# Specify a custom output file
./dns-probe.sh -o my-results.csv example.com

# Full path
./dns-probe.sh -o /tmp/dns-test-results.csv example.com
```

### Complete Example

```bash
# Run a 2-hour test with 3-second intervals, custom output
./dns-probe.sh -i 3 -m 2400 -o dns-test-$(date +%Y%m%d).csv new-domain.example.com
```

## Output

### Console Output

The script provides real-time colored output showing:
- When each probe starts
- Progress updates every 10 attempts
- Success messages with timing information
- Final summary when all probes complete

Example:
```
╔════════════════════════════════════════════════════════╗
║    DNS Probe Script - Parallel Testing                ║
╚════════════════════════════════════════════════════════╝

Domain: example.com
Interval: 5s between probes
Max attempts per probe: unlimited
Note: Suitable for long-running tests (1-3 hours or more)

Starting DNS probes at: Tue Nov 11 10:30:00 PST 2025
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Output file created: dns-probe-results-20251111_103000.csv

Launching all probes in parallel...

[1/5] Probing with default OS DNS configuration...
Probing with DNS server 1.1.1.1 (Cloudflare 1.1.1.1)...
Probing with DNS server 9.9.9.9 (Quad9 9.9.9.9)...
Probing with DNS server 8.8.8.8 (Google 8.8.8.8)...
Probing with DNS over HTTPS (1.1.1.1)...

All probes running in parallel (PIDs: 12345 12346 12347 12348 12349)
Waiting for all probes to complete...
(This may take 1-3 hours or until DNS records are found)

  [Default OS DNS] Attempt 1...
  [Cloudflare 1.1.1.1] Attempt 1...
  [Quad9 9.9.9.9] Attempt 1...
  [Google 8.8.8.8] Attempt 1...
  [DoH] Attempt 1...
  ...
  ✓ [Cloudflare 1.1.1.1] DNS record found after 127s (26 attempts)
    Time: 2025-11-11 10:32:07
    Result: 93.184.216.34
```

### CSV Output File

The script creates a CSV file with the following columns:

| Column | Description |
|--------|-------------|
| `Probe Method` | Name of the DNS probe method |
| `Start Time` | Human-readable start timestamp |
| `Start Timestamp` | Unix epoch start time |
| `Resolution Time` | Human-readable resolution timestamp |
| `Resolution Timestamp` | Unix epoch resolution time |
| `Duration (seconds)` | Time taken to resolve |
| `Attempts` | Number of probe attempts |
| `Result` | DNS resolution result (IP addresses) |
| `Status` | SUCCESS or TIMEOUT |

Example CSV content:
```csv
Probe Method,Start Time,Start Timestamp,Resolution Time,Resolution Timestamp,Duration (seconds),Attempts,Result,Status
Cloudflare 1.1.1.1,2025-11-11 10:30:00,1699722600,2025-11-11 10:32:07,1699722727,127,26,"93.184.216.34",SUCCESS
Default OS DNS,2025-11-11 10:30:00,1699722600,2025-11-11 10:32:15,1699722735,135,27,"93.184.216.34",SUCCESS
Google 8.8.8.8,2025-11-11 10:30:00,1699722600,2025-11-11 10:32:20,1699722740,140,28,"93.184.216.34",SUCCESS
```

### Analyzing Results

```bash
# View the results as a formatted table
column -t -s',' dns-probe-results-*.csv | less

# Get just the successful probes
grep "SUCCESS" dns-probe-results-*.csv

# Sort by duration to see which DNS resolved fastest
(head -n 1 dns-probe-results-*.csv && tail -n +2 dns-probe-results-*.csv | sort -t',' -k6 -n)

# Calculate average resolution time
awk -F',' 'NR>1 && $9=="SUCCESS" {sum+=$6; count++} END {print "Average:", sum/count, "seconds"}' dns-probe-results-*.csv
```

## Runtime Calculations

For planning your test runs:

| Interval | Attempts | Total Time |
|----------|----------|------------|
| 2s | 1800 | 1 hour |
| 3s | 1200 | 1 hour |
| 5s | 720 | 1 hour |
| 5s | 2160 | 3 hours |
| 10s | 1080 | 3 hours |

## Interrupting the Script

To stop the script gracefully:
- Press `Ctrl+C`
- All background processes will be cleaned up
- Partial results will be saved to the output file

## Troubleshooting

### "dig: command not found"

**macOS:**
```bash
brew install bind
```

**RHEL:**
```bash
sudo dnf install bind-utils
```

### "curl: command not found"

**RHEL:**
```bash
sudo dnf install curl
```

### Script runs but no output file

Check that you have write permissions in the current directory:
```bash
ls -la
pwd
```

Specify an explicit output path:
```bash
./dns-probe.sh -o /tmp/dns-results.csv example.com
```

### Results show all TIMEOUT

- Verify the domain name is correct
- Check that DNS propagation hasn't occurred yet (expected for new domains)
- Try reducing the interval: `-i 2`
- Check internet connectivity

## Use Cases

### 1. New Domain Setup
Monitor when a newly registered domain becomes available in DNS:
```bash
./dns-probe.sh -i 5 mynewdomain.com
```

### 2. DNS Propagation Testing
Test how long it takes for DNS changes to propagate:
```bash
./dns-probe.sh -i 3 -m 1200 updated-domain.com
```

### 3. Multi-DNS Comparison
Compare resolution times across different DNS providers:
```bash
./dns-probe.sh -i 10 -o comparison-$(date +%Y%m%d).csv test-domain.com
```

### 4. Long-Running Monitoring
Run overnight to catch DNS propagation:
```bash
# 3-hour test with 5-second intervals
nohup ./dns-probe.sh -i 5 -m 2160 -o overnight-test.csv domain.com &
```

## Platform-Specific Notes

### macOS

- `dig` may already be available on recent macOS versions
- `column` command is available by default for formatted output
- Colors display correctly in Terminal.app and iTerm2

### RHEL 9/10

- Install `bind-utils` package for `dig` command
- `column` is part of `util-linux` package (usually pre-installed)
- Colors display correctly in standard terminals
- Tested on RHEL 9.0+ and compatible distributions (AlmaLinux, Rocky Linux)

## Performance Considerations

- **CPU Usage**: Minimal - mostly idle waiting between probes
- **Memory Usage**: < 50MB total for all 5 parallel probes
- **Network Usage**: Very low - small DNS queries every N seconds
- **Disk Usage**: CSV file typically < 1KB per hour

## Advanced Usage

### Running in Background

```bash
# Run in background with nohup
nohup ./dns-probe.sh -i 5 example.com > dns-probe.log 2>&1 &

# Check progress
tail -f dns-probe.log

# View results while running
watch -n 10 'tail -n 10 dns-probe-results-*.csv'
```

### Automation with Cron

```bash
# Add to crontab to run daily at 2 AM
0 2 * * * /path/to/dns-probe.sh -i 5 -m 720 -o /var/log/dns-probe-$(date +\%Y\%m\%d).csv test-domain.com
```

### Integration with Monitoring

```bash
# Parse results and send alert when resolved
./dns-probe.sh -i 5 example.com
if grep -q "SUCCESS" dns-probe-results-*.csv; then
    # Send notification (e.g., via email, Slack, etc.)
    echo "DNS resolved!" | mail -s "DNS Alert" admin@example.com
fi
```

## Support

For issues or questions:
1. Verify all requirements are installed
2. Check the script's help: `./dns-probe.sh --help`
3. Review the output CSV file for detailed results
4. Check system DNS configuration: `cat /etc/resolv.conf` (Linux) or `scutil --dns` (macOS)

## License

MIT License - Free to use and modify.

