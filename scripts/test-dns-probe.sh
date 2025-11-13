#!/bin/bash
#
# Quick test script for dns-probe.sh
# This demonstrates basic usage and validates the environment

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "DNS Probe Script - Environment Validation"
echo "=========================================="
echo ""

# Check for required tools
echo "Checking required tools..."
echo ""

tools_ok=true

if command -v dig &> /dev/null; then
    echo -e "${GREEN}✓ dig is installed${NC}"
    dig -v 2>&1 | head -n 1
else
    echo -e "${RED}✗ dig is NOT installed${NC}"
    echo "  Install: brew install bind (macOS) or sudo dnf install bind-utils (RHEL)"
    tools_ok=false
fi

echo ""

if command -v curl &> /dev/null; then
    echo -e "${GREEN}✓ curl is installed${NC}"
    curl --version | head -n 1
else
    echo -e "${RED}✗ curl is NOT installed${NC}"
    echo "  Install: sudo dnf install curl (RHEL)"
    tools_ok=false
fi

echo ""

if command -v column &> /dev/null; then
    echo -e "${GREEN}✓ column is installed (for formatted output)${NC}"
else
    echo -e "${YELLOW}⚠ column is NOT installed (optional, output formatting will be limited)${NC}"
fi

echo ""
echo "=========================================="
echo ""

if [ "$tools_ok" = false ]; then
    echo -e "${RED}Some required tools are missing. Please install them first.${NC}"
    exit 1
fi

echo -e "${GREEN}All required tools are available!${NC}"
echo ""
echo "You can now run the DNS probe script. Examples:"
echo ""
echo "  # Quick test with google.com (should resolve immediately)"
echo "  ./dns-probe.sh -i 2 -m 10 google.com"
echo ""
echo "  # Long-running test for a new domain (1 hour, 5-second intervals)"
echo "  ./dns-probe.sh -i 5 -m 720 new-domain.example.com"
echo ""
echo "  # Background test with custom output"
echo "  nohup ./dns-probe.sh -i 5 example.com > dns-probe.log 2>&1 &"
echo ""

# Optional: Run a quick test
read -p "Run a quick test with google.com (10 attempts max)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Running quick test..."
    echo ""
    ./dns-probe.sh -i 2 -m 10 -o test-results.csv google.com
    
    echo ""
    echo "Test complete! Check test-results.csv for output."
    if [ -f test-results.csv ]; then
        echo ""
        echo "Results preview:"
        if command -v column &> /dev/null; then
            column -t -s',' test-results.csv
        else
            cat test-results.csv
        fi
    fi
fi

