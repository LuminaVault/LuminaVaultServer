#!/usr/bin/env python3
"""
Crypto Threshold Alert — Check BTC, ETH, SUI prices against thresholds.

Fetches live prices from CoinGecko public API (no key required) and emits
an alert if ANY cryptocurrency is at or below its threshold.

Alerts format:
  🚨 CRYPTO ALERT
  BTC  ≤ $75,000  | Current: $74,200
  ETH  ≤ $2,200   | Current: $2,150
  SUI  ≤ $0.95    | Current: $0.92

Usage: This script is designed for cron execution (every 2h).
Output goes to stdout; cron delivers to assigned platform.
"""

import urllib.request, json, sys, os

# ─── Thresholds ────────────────────────────────────────────────────────────────
THRESHOLDS = {
    "BTC": 75000.0,   # Bitcoin
    "ETH": 2200.0,    # Ethereum
    "SUI": 0.95,      # Sui
}

COINGECKO_IDS = {
    "BTC": "bitcoin",
    "ETH": "ethereum",
    "SUI": "sui",
}

UA = "HermesCryptoAlert/1.0 (+https://hermes.dev)"
COINGECKO_URL = "https://api.coingecko.com/api/v3/simple/price?ids={}&vs_currencies=usd"


def fetch_prices() -> dict:
    """Return dict: {symbol: float_price} for all tracked cryptos."""
    ids = ",".join(COINGECKO_IDS.values())
    url = COINGECKO_URL.format(ids)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        print(f"ERROR: Failed to fetch prices — {e}", file=sys.stderr)
        return {}

    prices = {}
    for symbol, cg_id in COINGECKO_IDS.items():
        price = data.get(cg_id, {}).get("usd")
        if price is not None:
            prices[symbol] = float(price)
    return prices


def check_thresholds(prices: dict) -> list[tuple[str, float, float]]:
    """Return list of (symbol, threshold, current_price) for breached tickers."""
    breaches = []
    for symbol, threshold in THRESHOLDS.items():
        price = prices.get(symbol)
        if price is None:
            continue  # skip if price fetch failed
        if price <= threshold:
            breaches.append((symbol, threshold, price))
    return breaches


def format_alert(breaches: list[tuple[str, float, float]]) -> str:
    if not breaches:
        return ""

    lines = []
    lines.append("**🚨 CRYPTO ALERT — Threshold Breached**\n")
    for symbol, threshold, price in breaches:
        emoji = "🔴" if price < threshold * 0.95 else "🟡"
        lines.append(f"{emoji} **{symbol}**  Threshold ≤ ${threshold:,.2f}")
        lines.append(f"   Current:  ${price:,.2f}")
        lines.append("")  # blank line
    lines.append(f"_Checked: {len(THRESHOLDS)} cryptos | Source: CoinGecko_")
    return "\n".join(lines)


def main():
    prices = fetch_prices()
    if not prices:
        print("ERROR: Could not fetch any prices", file=sys.stderr)
        return 1

    breaches = check_thresholds(prices)
    alert_msg = format_alert(breaches)

    if alert_msg:
        print(alert_msg)
        return 1  # non-zero exit indicates an alert condition
    else:
        # All clear — print nothing (cron will deliver empty = no message)
        # Or optionally print a quiet "all clear" for debugging:
        # print(f"OK — {', '.join(f'{s}:${p:.2f}' for s,p in prices.items())}")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
