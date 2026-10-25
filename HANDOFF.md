# HANDOFF: SAP read-only query API for an AI service

Context transfer for a Claude Code session running on the Windows machine that has
VPN access to the SAP system. Read this file fully before doing anything.

## Goal
Build a read-only HTTP API inside SAP (ABAP) that an AI service calls to answer
questions about finance data (BSEG and related tables). No writes to SAP, ever.
The AI service will use the JSON-Schema tool definitions in `sap_query.py`.

## What exists and is verified working
- ABAP class `ZCL_BSEG_API` (source: `zcl_bseg_api.abap`) implementing
  `IF_HTTP_EXTENSION`. Despite the name it serves a whitelist of tables, not just BSEG.
- SICF node `/default_host/sap/bc/zquery` registered with that handler and activated.
- System: S/4HANA, ABAP release 7.57, SID AC38.
  Base URL: `https://SAPAPPDEV.ambujagroup.com:44300/sap/bc/zquery`
  Auth: HTTP basic with the SAP user. Pass `sap-client=NNN` on every call.
- Verified from this Windows box with curl:
  - `/tables` returns the 14 whitelisted tables.
  - `/query` on T001 (client 100) returns company codes, including 1000 "Gujarat Ambuja Exp Ltd".
  - `/query` and `/aggregate` on BKPF, BSEG, ACDOCA in client 100 return 0 rows
    with no error, so the dynamic SQL path executes fine.

## Open issue (do this first)
Client 100 has NO posting data (BKPF and ACDOCA both empty). It is a customizing-only
client. Find the client that holds transactional data:
1. In SAP GUI run `SCC4` to list clients, or ask which client the user logs into.
2. Test: `curl -k -u USER:PASS "https://SAPAPPDEV.ambujagroup.com:44300/sap/bc/zquery/query?sap-client=NNN&table=BKPF&fields=bukrs,belnr,gjahr,budat&top=5"`
3. A German "401 Nicht autorisiert" HTML page means the user does not exist in that
   client; Basis must create it. Rows back means use that client from now on.
Once data is found, run the full smoke test (`test.sh`, or the curl list below) and
check the `/aggregate` output has numeric SUM_DMBTR and CNT values.

## Endpoints (all GET)
| Path | Params |
|---|---|
| `/tables` | none |
| `/meta` | `table` |
| `/query` | `table, fields, filter, orderby, top (<=5000, default 100), skip` |
| `/aggregate` | `table, groupby, sum, avg, min, max, filter, orderby, top` (always adds COUNT(*) as CNT; aggregates are aliased SUM_FIELD, AVG_FIELD, ...) |
| `/document` | `bukrs, belnr, gjahr` (BKPF header + BSEG items) |

Filter syntax: `field op value` joined by `;` (ANDed). Ops: `eq ne gt ge lt le cp np in bt`.
Examples: `bukrs eq 1000;gjahr eq 2025;koart eq K;dmbtr gt 10000`,
`hkont in 400000,400100;budat bt 20250101,20251231`, `sgtxt cp *rent*`.
Dates are YYYYMMDD. ALPHA-padded fields (BELNR, HKONT, LIFNR, KUNNR) are padded server-side.
Whitelist lives in constant `c_allowed` in the class; add a table there and reactivate.

## Smoke test (cmd.exe)
```
set B=https://SAPAPPDEV.ambujagroup.com:44300/sap/bc/zquery
set A=-k -s -u USER:PASS
curl %A% "%B%/tables?sap-client=NNN"
curl %A% "%B%/meta?sap-client=NNN&table=BSEG"
curl %A% -G "%B%/query" --data-urlencode "sap-client=NNN" --data-urlencode "table=BSEG" --data-urlencode "fields=belnr,buzei,koart,shkzg,hkont,dmbtr,sgtxt" --data-urlencode "filter=bukrs eq 1000;gjahr eq 2025" --data-urlencode "orderby=dmbtr desc" --data-urlencode "top=5"
curl %A% -G "%B%/aggregate" --data-urlencode "sap-client=NNN" --data-urlencode "table=BSEG" --data-urlencode "groupby=koart,shkzg" --data-urlencode "sum=dmbtr" --data-urlencode "filter=bukrs eq 1000;gjahr eq 2025"
curl %A% "%B%/document?sap-client=NNN&bukrs=1000&belnr=1900000001&gjahr=2025"
```

## Gotchas learned
- SE24 source-code-based editor refuses to save if there are comments outside the
  CLASS statements or between methods. Keep `zcl_bseg_api.abap` free of those.
- Writes to BSEG/BKPF/ACDOCA directly are forbidden. If writes are ever needed, use
  BAPI_ACC_DOCUMENT_POST / BAPI_ACC_DOCUMENT_REV_POST. Out of scope for now.
- BSEG amounts (DMBTR/WRBTR) are unsigned; SHKZG H=credit, S=debit. ACDOCA.HSL is signed
  and usually the better table for finance questions.
- The user's own password was pasted into the earlier chat; it should be changed, and a
  separate display-only technical SAP user should be created for the AI service.

## Next steps after data is found
1. Confirm all five endpoints return sensible data in the right client.
2. Decide LLM provider/SDK and where the AI service runs (new service vs the existing
   FastAPI monolith). Then write the tool-calling loop using `SAP_TOOLS` and
   `SapQuery.call_tool()` from `sap_query.py`.
3. Request from Basis: technical user with display-only FI roles + S_ICF for node zquery.
4. Consider adding tables to `c_allowed` as the AI needs them (e.g. T000 is cross-client
   and lists clients; MARA/MAKT for materials; EKKO/EKPO for purchasing).

## Prompt to paste into the new Claude Code session
"Read HANDOFF.md in this folder. We are continuing the SAP query API project. Start
with the open issue: find the SAP client that has posting data and re-run the smoke
tests against it. Then help me wire the AI service."
