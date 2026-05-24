---
name: investment-research
description: "Comprehensive investment research platform: thought leader tracking, institutional flows, earnings intelligence, portfolio stress testing, and diversification analysis for equities, crypto, and prediction markets."
license: MIT
---

# Investment Research Platform

Comprehensive framework for automated investment analysis and research delivery. Integrates multiple data streams to provide actionable insights, risk monitoring, and portfolio optimization.

## When to Use

Build this system when you need to:

- Track investment theses across multiple asset classes (equities, crypto, prediction markets)
- Monitor thought leaders and institutional movements
- Analyze earnings reports and market sentiment
- Stress test portfolios under various scenarios
- Generate diversification reports and rebalancing recommendations
- Deliver automated briefs to multiple platforms (Discord, Telegram, Slack, Email)

## Core Components

### 1. Thought Leader Monitoring
Track analysts, economists, and investors whose insights align with your investment theses.

**Implementation:**
- Connect to Twitter/X API, YouTube, news feeds
- Parse content for investment-relevant insights
- Score sentiment and categorize by theme
- Store in structured format for briefing generation

### 2. Institutional Flow Analysis
Monitor 13F filings, insider trading, and institutional positioning changes.

**Implementation:**
- Fetch data from SEC EDGAR, WhaleWisdom, or specialized APIs
- Track changes by institution, ticker, and direction
- Flag significant movements (e.g., +23% position increase)
- Correlate with price action and news

### 3. Earnings Intelligence
Maintain earnings calendar and automated call analysis.

**Implementation:**
- Fetch earnings data from financial APIs
- Compare consensus estimates vs. actual results
- Analyze sentiment and key themes (AI, Cloud, Enterprise)
- Generate pre- and post-earnings insights

### 4. Portfolio Stress Testing
Scenario analysis under various market conditions.

**Implementation:**
- Define stress test scenarios (financial crises, inflation shocks, rate surges)
- Model portfolio impact under each scenario
- Estimate recovery timelines
- Provide concrete mitigation recommendations

### 5. Diversification Dashboard
Real-time allocation tracking and optimization.

**Implementation:**
- Calculate current allocation across asset classes
- Compare against target bands
- Flag concentration risks (single positions >15%, sector overweights)
- Generate rebalancing recommendations
- Schedule regular review dates

## Configuration Schema

```yaml
user_profile:
  name: "[𝓓𝓻𝓪𝓬𝓪𝓻𝔂𝓼 𝓣𝓲𝓰𝓮𝓻]"
  risk_appetite: "moderate-to-aggressive"
  time_horizon: "long-term"
  liquidity_needs: "medium"
  tax_considerations: "tax-efficient investing"
  circle_of_confidence: ["yourself", "Hermes", "selected analysts"]

investment_theses:
  thesis_1: "AI and automation will drive productivity gains across all sectors"
  thesis_2: "Decentralization trends will reshape finance and technology infrastructure"
  thesis_3: "Emerging market adoption of advanced technologies will accelerate"

current_positions:
  equities: [
    {"ticker": "NVDA", "position": 15.4, "rationale": "AI chip monopoly"},
    {"ticker": "MSFT", "position": 12.1, "rationale": "Cloud infrastructure"}
  ]
  crypto: [
    {"asset": "BTC", "position": 10.5, "rationale": "Store of value"},
    {"asset": "ETH", "position": 8.2, "rationale": "Smart contract platform"}
  ]
  prediction_markets: [
    {"platform": "Polymarket", "position": 7.3, "rationale": "Information aggregation"}
  ]

target_allocation:
  equities: "40-50%"
  crypto: "15-25%"
  prediction_markets: "5-10%"
  cash: "10-15%"
  alternatives: "5-10%"

thought_leaders:
  macro: ["Stanley Druckenmiller", "Ray Dalio"]
  tech: ["Cathie Wood", "Dan Ives"]
  crypto: ["Michael Saylor", "Vitalik Buterin"]

stress_test_scenarios:
  - "2008-style financial crisis"
  - "2020 COVID crash"
  - "2022 inflation shock"
  - "Interest rate surge"
  - "Geopolitical conflict escalation"

monitoring:
  earnings_calendar: true
  institutional_flows: true
  insider_trading: true
  economic_indicators: ["CPI", "PPI", "GDP", "Unemployment"]
  sector_rotations: ["Technology", "Healthcare", "Financials"]
```

## Delivery Patterns

### Multi-Platform Delivery
Use the standard scheduled reports delivery wrapper pattern for Discord, Telegram, Slack, and Email.

### Timing Strategy
- **Morning (7:00 AM)**: Comprehensive overview, thought leader insights
- **Afternoon (2:00 PM)**: Market movement analysis, institutional flows
- **Evening (8:00 PM Sunday)**: Weekly stress tests, rebalancing recommendations

### Content Structure
```markdown
# 📈 Daily Investment Brief
**Generated:** 2026-05-04 22:13
**For:** [𝓓𝓻𝓪𝓬𝓪𝓻𝔂𝓼 𝓣𝓲𝓰𝓮𝓻]

## 🔥 Top Investment Insights
1. **Stanley Druckenmiller** (macro)
   🟢 Advocates for increased macro exposure amid favorable conditions

## 🏦 Institutional Flow Analysis
- **Renaissance Technologies** increased NVDA by +23% ($1.2B)

## 📊 Earnings Intelligence
### This Week's Key Reports:
- **AAPL** (2026-05-06) Consensus: $1.52 | Estimate: $1.48 | Sentiment: POSITIVE

## 🏥 Portfolio Health Check
- **Current Allocation:** Equities: 38.1%, Crypto: 23.8%
- **Concentration Risks:** NVDA position exceeds 15%, Crypto near upper target
- **Next Review:** 2026-06-03

## 💥 Stress Test Results
- **2008-style financial crisis** Impact: -12.4% | Recovery: 18 months

## ✅ Action Items
- Trim NVDA to 10% over next quarter
- Reduce crypto exposure to 15%
```

## Technical Implementation

### Data Types Matter
- Use numeric values for percentages (not strings with % signs) to enable mathematical operations
- Store positions as floats for accurate calculations
- Parse percent strings with `.rstrip('%')` when reading from external sources

### Python Script Best Practices
- Be careful with escape sequences in multi-line strings; prefer raw strings or proper escaping
- Use `#!/usr/bin/env python3` shebang
- Structure code with clear class-based organization
- Implement proper error handling for external API failures

### Cron Job Setup
```bash
hermes cron create --name="Investment Brief Morning" --schedule="0 7 * * *" --script="investment_research.py" --deliver="origin"
hermes cron create --name="Thought Leader Tracking" --schedule="0 8 * * *" --script="investment_research.py" --deliver="origin"
hermes cron create --name="Weekly Stress Test" --schedule="0 20 * * 0" --script="investment_research.py" --deliver="origin"
```

### Dependencies
```txt
yfinance       # price data
pandas         # data manipulation
matplotlib     # charting (Agg backend)
feedparser     # RSS sentiment (optional)
sec-edgar-downloader  # insider filings (optional)
python-dotenv  # .env loading
```

## Integration with Existing Systems

### With Daily Briefings
Investment research can be combined with general news briefings for a unified daily digest, or delivered as separate specialized briefs.

### With Knowledge Base
Persist reports to Obsidian vault for long-term knowledge retention and cross-referencing.

### With Alert Systems
Integrate with existing threshold alert systems for real-time monitoring of critical changes.

## Verification Checklist

Before considering production-ready:

- [ ] `--root` config accepts custom path; defaults to script directory
- [ ] Main script outputs Markdown to stdout (test with `python report.py --root . | head`)
- [ ] Vault directory exists and is writable by Hermes user (UID 1000)
- [ ] Cron job created with `hermes cron create` using script relative to `~/.hermes/scripts/`
- [ ] Wrapper sources `/opt/data/.env` so tokens are available in cron environment
- [ ] Test run: `hermes cron run <job_id>` produces output in origin chat and vault file
- [ ] Check cron logs: `tail -f ~/.hermes/logs/cron.log` for errors
- [ ] Verify duplicate suppression: alert script exits 0 on cooldown

## Support Files

- `references/investment-research-profile.md` — Sample configuration and schema
- `templates/investment-config.yaml` — Starter configuration file
- `scripts/investment-research.py` — Main research platform script

## Related Skills

- `scheduled-reports` — Core patterns for automated report pipelines
- `stock-trading` — Portfolio tracking and threshold alerts
- `knowledge-base` — Vault persistence and knowledge management
- `cron-deployment` — Hermes cron mechanics and script management