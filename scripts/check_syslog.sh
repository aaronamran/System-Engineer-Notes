#!/bin/bash

servers=(
172.24.66.25
172.24.66.27
172.24.66.30
172.24.66.31
172.24.66.32
172.24.66.33
172.24.66.34
172.24.66.35
172.24.66.36
172.24.66.37
172.24.66.111
172.24.66.112
172.24.66.113
172.24.66.114
172.24.66.115
172.24.66.116
172.24.66.117
172.24.66.118
172.24.67.26
172.24.67.27
172.24.67.28
172.24.67.29
172.24.67.30
172.24.67.31
172.24.67.32
)

logfiles="/var/log/messages*"   # scan all rotated messages files
# For typical rsyslog remote logs, most servers forward to messages (or sometimes secure for auth events). So scanning messages is usually enough

echo "===== Syslog Check: $(date) ====="

for ip in "${servers[@]}"; do
    if grep -q "$ip" $logfiles 2>/dev/null; then
        echo "[✔] $ip is sending logs"
    else
        echo "[✘] $ip NOT sending logs"
    fi
done


