#!/usr/bin/env python3
"""
Batch-split a long markdown digest into Discord-safe parts (≤1800 chars each).

Usage:
  python3 batch_digest_for_discord.py /path/to/input.md /path/to/output_batch_*.md

Logic:
  - Splits on H2 headings (## TICKER) to preserve section boundaries.
  - Accumulates sections until adding the next would exceed 1800 chars.
  - Starts a new batch when needed.
  - Writes each batch to a separate file (batch_01.md, batch_02.md, ...).

Output files can then be fed to send_message in sequence, with the final
batch also receiving the full digest as a file attachment.
"""

import re, sys, pathlib

def batch_digest(content, max_chars=1800):
    """Split markdown digest into batches ≤ max_chars, splitting on H2 sections."""
    # Split into sections by H2 headings (preserve heading with its content)
    sections = re.split(r'(?=^## [A-Za-z0-9]+$)', content, flags=re.MULTILINE)
    sections = [s.strip() for s in sections if s.strip()]

    batches = []
    current_batch = []
    current_len = 0

    for section in sections:
        section_len = len(section) + 2  # +2 for "\n\n" between sections
        if current_len + section_len > max_chars and current_batch:
            # Flush current batch and start new
            batches.append("\n\n".join(current_batch))
            current_batch = [section]
            current_len = section_len
        else:
            current_batch.append(section)
            current_len += section_len

    if current_batch:
        batches.append("\n\n".join(current_batch))

    return batches

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: batch_digest_for_discord.py <input.md> <output_prefix>")
        print("Example: batch_digest_for_discord.py digest.md batch_")
        print("  → creates batch_01.md, batch_02.md, ...")
        sys.exit(1)

    input_path = pathlib.Path(sys.argv[1])
    output_prefix = sys.argv[2]

    content = input_path.read_text()
    batches = batch_digest(content, max_chars=1800)

    for i, batch in enumerate(batches, 1):
        out_path = pathlib.Path(f"{output_prefix}{i:02d}.md")
        out_path.write_text(batch)
        print(f"✓ {out_path} — {len(batch)} chars")

    print(f"\nTotal batches: {len(batches)}")
