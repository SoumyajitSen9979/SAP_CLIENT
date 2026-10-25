# sap-query-api

Read-only generic query API inside SAP (ABAP, SICF handler) plus a Python client
for an AI service to call.

## Files
- `zcl_bseg_api.abap` – paste into class `ZCL_BSEG_API` (SE24 > Source Code-Based, or ADT), activate.
- `sap_query.py` – Python client + JSON-Schema tool definitions for an LLM tool-calling loop.
- `test.sh` – curl smoke tests.

## Install in SAP
1. SE24 > Create `ZCL_BSEG_API` (package `$TMP` or your Z package) > Source Code-Based > paste > Ctrl+F3.
2. SICF > F8 > default_host > sap > bc > right-click > New Sub-Element `zquery` > Handler List: `ZCL_BSEG_API` > Save > Activate Service.
3. SMICM > Goto > Services for host and port.

## Endpoints (all GET, basic auth, `sap-client=NNN`)
| Path | Params |
|---|---|
| `/tables` | – |
| `/meta` | `table` |
| `/query` | `table, fields, filter, orderby, top (<=5000), skip` |
| `/aggregate` | `table, groupby, sum, avg, min, max, filter, orderby, top` |
| `/document` | `bukrs, belnr, gjahr` |

Filter: `field op value;field op value` with ops `eq ne gt ge lt le cp np in bt`.

## Add tables
Append to constant `c_allowed` in the class and reactivate.
