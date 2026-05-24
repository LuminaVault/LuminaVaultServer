import os
import subprocess

ref_dir = '/opt/data/skills/stock-trading/portfolio-threshold-monitoring/references'
print("References directory:")
for f in sorted(os.listdir(ref_dir)):
    path = os.path.join(ref_dir, f)
    print(f"  {f} ({os.path.getsize(path)} bytes)")

print("\nChecking skill for 'symlink' mentions:")
result = subprocess.run(['grep','-n','symlink','/opt/data/skills/stock-trading/portfolio-threshold-monitoring/SKILL.md'],
                       capture_output=True, text=True)
print(result.stdout[:2000])