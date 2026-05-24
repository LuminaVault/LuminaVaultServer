#!/bin/bash
# Stock ticker X search wrapper — one-liners for all tracked tickers
# Uses xurl; requires X API credits available.

TICKERS=(
  ZETA AMD AMZN HIMS OSCR SOFI KRKNF ONDS ABCL GRAB
  ASTS TE UBER NFLX NVO NKE SIDU SMR FLNC RDW
)

MODE=${1:-search}   # "search" (default) or "follow-suggestions"
LIMIT=${2:-10}

if [ "$MODE" = "search" ]; then
  # Build combined cashtag query
  QUERY=$(printf "$%s " "${TICKERS[@]}")
  echo "Searching: $QUERY (limit: $LIMIT tweets)"
  xurl search "$QUERY -filter:retweets" -n "$LIMIT"

elif [ "$MODE" = "follow" ]; then
  # Suggest accounts to follow (run the Python script)
  python3 ~/.hermes/scripts/follow_tickers.py --digest --max-tweets 5

else
  echo "Usage: $0 {search|follow} [tweet-limit]"
  echo "  search  — combined search across all tickers"
  echo "  follow  — show recent tweets/posts per ticker (suggests accounts)"
fi
