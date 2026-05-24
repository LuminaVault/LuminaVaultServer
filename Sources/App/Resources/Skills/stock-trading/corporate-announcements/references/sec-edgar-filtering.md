# SEC EDGAR Ticker Filtering

**Skill**: `corporate-announcements` | **Used in**: `filter_watchlist(entries, watchlist)`

## Problem

SEC EDGAR RSS titles embed either a ticker symbol or a CIK number inside parentheses, e.g.:

```
8-K — Company Name (ZETA)
8-K — Another Co (AMD)
Form 4 — Insider Trade (CIK0001234567)
```

Naive substring matching (`if "ZETA" in title`) produces **false positives**:
- CIK `110698` contains `106` which matches nothing? Actually careful — but tickers like `SOFI` could theoretically appear as part of a CIK? Unlikely but possible.
- More importantly, short tickers (2–3 letters) frequently appear inside longer company names: `"SO"` in `"Company"`, `"AMD"` in `"AMAZON"` — false match.

## Solution: Strict Parens Pattern

1. **Require parentheses**: Match only substrings that are inside `(` and `)` in the title.
2. **Exact ticker set**: Use a regex alternation group of ALL watchlist tickers (case-insensitive).
3. **Extract by slice**: After regex match, strip the surrounding parens via `match.group(0)[1:-1]`.

### Code Pattern

```python
import re

# Compile once at module load — lowercase alternation for case-insensitive match
TICKER_PATTERN = re.compile(
    r'\((?:' + '|'.join(sorted(tickers, key=len, reverse=True)) + r')\)',
    re.IGNORECASE
)

def extract_ticker(title: str) -> str | None:
    """Return ticker if title contains a watchlist ticker inside parentheses, else None."""
    m = TICKER_PATTERN.search(title)
    if m:
        # m.group(0) includes parens; strip them
        return m.group(0)[1:-1].upper()
    return None

# Usage in filter loop:
for entry in entries:
    ticker = extract_ticker(entry.title)
    if ticker and ticker in WATCHLIST_SET:
        # keep entry
```

## Why Not Word Boundaries?

Attempted: `r'\b(?:ZETA|AMD)\b'` fails because parentheses are non-word characters; `\b` fails to match at the `(` boundary. Using `(?<=\()` lookbehind would work but variable-length lookbehind is not supported in Python's `re` for alternations of different lengths.

## Edge Cases Handled

| Title example | Match? | Why |
|---|---|---|
| `8-K — Zeta Corp (ZETA)` | ✅ `ZETA` | Parens + exact ticker |
| `Form 4 — Insider (CIK0001234567)` | ❌ | CIK is all digits, not in watchlist |
| `8-K — Amazon (AMZN)` | ✅ `AMZN` | Clean parens |
| `8-K — Advanced Micro Devices (AMD)` | ✅ `AMD` | Ticker is word itself inside parens |
| `8-K — Some Co (SO)` | ❌ (if `SO` not in watchlist) | Even if `SO` were a ticker, it's not in our list |
| `8-K — Company (XYZ)` | ❌ | `XYZ` not in watchlist |

## Performance Note

Regex compilation is cheap (<1 ms for 25-ticker pattern). Do **not** rebuild the pattern inside a loop; compile once at module scope.

## Test Vectors (quick sanity check)

```python
tests = [
    ("8-K — Zeta (ZETA)", "ZETA"),
    ("Form 4 — Trade (AMD)", "AMD"),
    ("8-K — Clarity (ABCL)", "ABCL"),
    ("8-K — Grab (GRAB)", "GRAB"),
    ("Form 4 — CIK000110698 (FAKE)", None),  # CIK not a ticker
    ("8-K — Some Co (SOMETHING)", None),      # not in watchlist
]

for title, expected in tests:
    assert extract_ticker(title) == expected, title
```
