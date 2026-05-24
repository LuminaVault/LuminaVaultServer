#!/bin/bash
# Download the iOS Architecture Guide to your current directory
echo "Downloading iOS Architecture Guide..."
scp -i /opt/data/.ssh/hermes_monitor_key root@ubuntu-4gb-fsn1-1:/opt/data/home/.hermes/scripts/iOS_Architecture_Guide.txt ./iOS_Architecture_Guide.txt
echo "✓ Downloaded to $(pwd)/iOS_Architecture_Guide.txt"
