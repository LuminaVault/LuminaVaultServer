## File Transfer Troubleshooting

When copying the rendered video from VPS to Mac, follow these steps:

### 1. Verify File Location
```bash
# Check if file exists
ls -la /tmp/knowledge-graph-final.mp4

# If not found but exists in Docker:
docker ps -a
docker exec <container_id> ls -la /tmp/knowledge-graph-final.mp4

# Copy from Docker to host:
docker cp <container_id>:/tmp/knowledge-graph-final.mp4 /tmp/
```

### 2. Permission Issues
If root can't access the file due to ownership:
```bash
# Create a root-accessible copy
cp /tmp/knowledge-graph-final.mp4 /tmp/knowledge-graph-final-root-copy.mp4

# Or change permissions
chmod 644 /tmp/knowledge-graph-final.mp4
```

### 3. Transfer from VPS to Mac

**From Mac terminal** (recommended):
```bash
rsync -avz hermes@78.46.192.73:/tmp/knowledge-graph-final.mp4 ~/Downloads/
# Password: Hermes2024!
```

**If SSH keys aren't working**:
```bash
# On Mac, generate SSH key if needed:
ssh-keygen -t ed25519

# Copy public key to VPS:
ssh hermes@78.46.192.73 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ~/.ssh/id_ed25519.pub
```

**Alternative methods**:
```bash
# SCP from VPS to Mac
scp /tmp/knowledge-graph-final-root-copy.mp4 your_mac_username@your_mac_ip:~/Downloads/

# HTTP server on VPS
python3 -m http.server 8000
# On Mac: curl http://vps_ip:8000/knowledge-graph-final-root-copy.mp4 -o ~/Downloads/
```

### 4. Common Errors & Fixes
- **"Permission denied"**: Use `hermes` user instead of `root`, or fix permissions.
- **"No such file"**: Verify file exists with `find /tmp -name "*.mp4"`.
- **Connection reset**: Check network connectivity; use `ssh -v hermes@78.46.192.73` to debug.

### 5. Quick Verification
```bash
# On Mac after transfer:
ls -lh ~/Downloads/knowledge-graph-final.mp4
file ~/Downloads/knowledge-graph-final.mp4
```

This covers the most common issues encountered during file transfer.