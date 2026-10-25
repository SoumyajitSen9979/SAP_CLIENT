"""
Python client for the ZCL_SAP_QUERY_API ABAP handler (SICF node /sap/bc/zquery).
Provider-neutral: the tool definitions at the bottom are plain JSON Schema.

Usage:
    sap = SapQuery("https://HOST:PORT/sap/bc/zquery", "USER", "PASS", client="100")
    sap.tables()
    sap.meta("BSEG")
    sap.query("BSEG", fields="belnr,buzei,dmbtr", filter="bukrs eq 1000;gjahr eq 2025", top=50)
    sap.aggregate("BSEG", groupby="hkont", sum="dmbtr", filter="bukrs eq 1000;gjahr eq 2025")
    sap.document("1000", "1900000001", "2025")
"""
import os
import requests
import urllib3


class SapQueryError(RuntimeError):
    pass


class SapQuery:
    def __init__(self, base_url, user, password, client, verify=False, timeout=60):
        self.base = base_url.rstrip("/")
        self.client = client
        self.timeout = timeout
        self.s = requests.Session()
        self.s.auth = (user, password)
        self.s.verify = verify
        if not verify:
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def _get(self, path, **params):
        params = {k: v for k, v in params.items() if v is not None}
        params["sap-client"] = self.client
        r = self.s.get(f"{self.base}/{path}", params=params, timeout=self.timeout)
        if r.status_code >= 400:
            try:
                msg = r.json().get("error", r.text)
            except ValueError:
                msg = r.text[:500]
            raise SapQueryError(f"{r.status_code} {path}: {msg}")
        return r.json()

    def tables(self):
        return self._get("tables")

    def meta(self, table):
        return self._get("meta", table=table)

    def query(self, table, fields=None, filter=None, orderby=None, top=100, skip=0):
        return self._get("query", table=table, fields=fields, filter=filter,
                         orderby=orderby, top=top, skip=skip)

    def aggregate(self, table, groupby=None, sum=None, avg=None, min=None, max=None,
                  filter=None, orderby=None, top=1000):
        return self._get("aggregate", table=table, groupby=groupby, sum=sum, avg=avg,
                         min=min, max=max, filter=filter, orderby=orderby, top=top)

    def document(self, bukrs, belnr, gjahr):
        return self._get("document", bukrs=bukrs, belnr=belnr, gjahr=gjahr)

    # Dispatch helper for an LLM tool-calling loop: name -> method
    def call_tool(self, name, args):
        fn = {
            "sap_tables": self.tables,
            "sap_meta": self.meta,
            "sap_query": self.query,
            "sap_aggregate": self.aggregate,
            "sap_document": self.document,
        }[name]
        return fn(**args)


FILTER_DOC = (
    "filter syntax: 'field op value' joined by ';' (all ANDed). "
    "ops: eq ne gt ge lt le cp (pattern, * wildcard) np (not pattern) "
    "in (comma list) bt (low,high). Dates are YYYYMMDD. "
    "Example: 'bukrs eq 1000;gjahr eq 2025;koart eq K;dmbtr gt 10000'. "
    "BSEG amounts DMBTR/WRBTR are unsigned: SHKZG='H' is credit, 'S' is debit. "
    "For signed ledger amounts use ACDOCA field HSL."
)

SAP_TOOLS = [
    {
        "name": "sap_tables",
        "description": "List the SAP tables that can be queried.",
        "input_schema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "sap_meta",
        "description": "Get the field list (name, key, type, description) of an SAP table. "
                       "Call this before querying a table whose fields you are not sure about.",
        "input_schema": {
            "type": "object",
            "properties": {"table": {"type": "string", "description": "e.g. BSEG"}},
            "required": ["table"],
            "additionalProperties": False,
        },
    },
    {
        "name": "sap_query",
        "description": "Read rows from an SAP table with filtering, column selection, sorting and paging. " + FILTER_DOC,
        "input_schema": {
            "type": "object",
            "properties": {
                "table":   {"type": "string", "description": "e.g. BSEG, BKPF, ACDOCA"},
                "fields":  {"type": "string", "description": "comma-separated field names; omit for all"},
                "filter":  {"type": "string"},
                "orderby": {"type": "string", "description": "e.g. 'dmbtr desc, belnr'"},
                "top":     {"type": "integer", "default": 100, "minimum": 1, "maximum": 5000},
                "skip":    {"type": "integer", "default": 0, "minimum": 0},
            },
            "required": ["table"],
            "additionalProperties": False,
        },
    },
    {
        "name": "sap_aggregate",
        "description": "Group rows of an SAP table and compute SUM/AVG/MIN/MAX plus a row count (CNT). "
                       "Result columns are named SUM_<field>, AVG_<field>, etc. " + FILTER_DOC,
        "input_schema": {
            "type": "object",
            "properties": {
                "table":   {"type": "string"},
                "groupby": {"type": "string", "description": "comma-separated fields, e.g. 'hkont,shkzg'"},
                "sum":     {"type": "string", "description": "comma-separated numeric fields"},
                "avg":     {"type": "string"},
                "min":     {"type": "string"},
                "max":     {"type": "string"},
                "filter":  {"type": "string"},
                "orderby": {"type": "string", "description": "group field or alias, e.g. 'sum_dmbtr desc'"},
                "top":     {"type": "integer", "default": 1000, "maximum": 5000},
            },
            "required": ["table"],
            "additionalProperties": False,
        },
    },
    {
        "name": "sap_document",
        "description": "Fetch one accounting document: BKPF header plus all BSEG line items.",
        "input_schema": {
            "type": "object",
            "properties": {
                "bukrs": {"type": "string", "description": "company code"},
                "belnr": {"type": "string", "description": "document number, leading zeros optional"},
                "gjahr": {"type": "string", "description": "fiscal year, e.g. 2025"},
            },
            "required": ["bukrs", "belnr", "gjahr"],
            "additionalProperties": False,
        },
    },
]


if __name__ == "__main__":
    import json
    sap = SapQuery(
        os.environ["SAP_URL"],            # https://HOST:PORT/sap/bc/zquery
        os.environ["SAP_USER"],
        os.environ["SAP_PASS"],
        client=os.environ.get("SAP_CLIENT", "100"),
    )
    print(json.dumps(sap.tables(), indent=2))
