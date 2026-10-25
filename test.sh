#!/usr/bin/env bash
# Smoke tests. Set these first:
#   export SAP_URL="https://HOST:PORT/sap/bc/zquery" SAP_USER=... SAP_PASS=... SAP_CLIENT=100
set -u
A=(-k -s -u "$SAP_USER:$SAP_PASS")
C="sap-client=${SAP_CLIENT:-100}"
B="$SAP_URL"

echo "== /tables";    curl "${A[@]}" "$B/tables?$C"; echo
echo "== /meta BSEG"; curl "${A[@]}" "$B/meta?$C&table=BSEG" | head -c 800; echo
echo "== /query";
curl "${A[@]}" -G "$B/query" --data-urlencode "$C" --data-urlencode "table=BSEG" \
  --data-urlencode "fields=bukrs,belnr,gjahr,buzei,koart,shkzg,dmbtr,sgtxt" \
  --data-urlencode "filter=bukrs eq ${BUKRS:-1000};gjahr eq ${GJAHR:-2025}" \
  --data-urlencode "orderby=dmbtr desc" --data-urlencode "top=5"; echo
echo "== /aggregate";
curl "${A[@]}" -G "$B/aggregate" --data-urlencode "$C" --data-urlencode "table=BSEG" \
  --data-urlencode "groupby=koart,shkzg" --data-urlencode "sum=dmbtr" \
  --data-urlencode "filter=bukrs eq ${BUKRS:-1000};gjahr eq ${GJAHR:-2025}"; echo
if [ -n "${BELNR:-}" ]; then
  echo "== /document";
  curl "${A[@]}" "$B/document?$C&bukrs=${BUKRS:-1000}&belnr=$BELNR&gjahr=${GJAHR:-2025}"; echo
fi
