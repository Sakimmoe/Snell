#!/bin/bash

# Exit on error
set -e

# Check root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31mError: Please run this script as root (e.g., using sudo).\033[0m"
  exit 1
fi

GAI_CONF="/etc/gai.conf"
RULE="precedence ::ffff:0:0/96  100"

# Create file if it doesn't exist
[ ! -f "$GAI_CONF" ] && touch "$GAI_CONF"

# Uncomment the rule if it exists as a comment
sed -i 's/^#\s*precedence ::ffff:0:0\/96\s*100/precedence ::ffff:0:0\/96  100/' "$GAI_CONF"

# Append the rule if it's completely missing
if ! grep -q "^$RULE" "$GAI_CONF"; then
    echo "$RULE" >> "$GAI_CONF"
fi

# Print success message in green
echo -e "\033[32m=========================================\033[0m"
echo -e "\033[32m Success: IPv4 priority is now enabled!  \033[0m"
echo -e "\033[32m=========================================\033[0m"

# Quick test
echo "Testing connection..."
curl -I -s -m 3 https://google.com | head -n 1 || echo "Test failed, but configuration was applied."
