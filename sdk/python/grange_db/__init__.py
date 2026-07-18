"""grange client SDK for Python (>=3.8, stdlib only — zero dependencies).

Works against the hosted instance (https://grange.intrane.fr/llms.txt) or any
`grange serve`.

    from grange_db import Grange
    g = Grange("https://grange.intrane.fr", "gt_...")
    leads = g.db("crm").coll("leads")
    doc_id = leads.put({"co": "acme", "score": 9})
    doc = leads.get(doc_id)                    # None if missing
    n = leads.count("score>=5")
    res = leads.find("co=acme", limit=50)      # {"count":..,"items":[{id,doc}..]}
    leads.put_many([{"co": "globex"}, ("l2", {"co": "initech"})])  # one commit
"""

import json as _json
import urllib.request as _rq
import urllib.parse as _up
import urllib.error as _er

__all__ = ["Grange", "GrangeError", "signup"]
__version__ = "0.8.0"


class GrangeError(Exception):
    def __init__(self, type_, message, status=0):
        super().__init__(f"grange: {type_}: {message}")
        self.type = type_
        self.status = status


class Grange:
    def __init__(self, url, token, db="default", coll="default", timeout=30):
        self.url = url.rstrip("/")
        self.token = token
        self._db = db
        self._coll = coll
        self.timeout = timeout

    def db(self, name):
        return Grange(self.url, self.token, db=name, coll=self._coll, timeout=self.timeout)

    def coll(self, name):
        return Grange(self.url, self.token, db=self._db, coll=name, timeout=self.timeout)

    @property
    def _qs(self):
        return _up.urlencode({"coll": self._coll, "db": self._db})

    def _req(self, method, path, body=None, raw_body=None, ctype="application/json"):
        data = raw_body.encode() if raw_body is not None else (
            _json.dumps(body, separators=(",", ":")).encode() if body is not None else None)
        req = _rq.Request(self.url + path, data=data, method=method, headers={
            "content-type": ctype, "authorization": "Bearer " + self.token})
        try:
            with _rq.urlopen(req, timeout=self.timeout) as resp:
                env = _json.loads(resp.read().decode())
        except _er.HTTPError as e:
            try:
                env = _json.loads(e.read().decode())
            except Exception:
                raise GrangeError("protocol", f"HTTP {e.code}", e.code) from None
            err = env.get("error") or {}
            raise GrangeError(err.get("type", "protocol"), err.get("message", ""), e.code) from None
        if not env.get("ok"):
            err = env.get("error") or {}
            raise GrangeError(err.get("type", "protocol"), err.get("message", ""))
        return env["data"]

    def put(self, doc, id=None, ttl_seconds=0):
        body = {"db": self._db, "coll": self._coll, "doc": doc}
        if id:
            body["id"] = id
        if ttl_seconds:
            body["ttl_seconds"] = ttl_seconds
        return self._req("POST", "/put", body)["id"]

    def get(self, id):
        try:
            return self._req("GET", f"/get?{self._qs}&id={_up.quote(id)}")["doc"]
        except GrangeError as e:
            if e.type == "not-found":
                return None
            raise

    def delete(self, id):
        self._req("POST", "/del", {"db": self._db, "coll": self._coll, "id": id})

    def find(self, where="", limit=100):
        """where: "f=v,f2>=v2" (ANDed; = > < >= <=). -> {count, mode, items}"""
        return self._req("GET", f"/find?{self._qs}&where={_up.quote(where)}&limit={limit}")

    def count(self, where=""):
        return self._req("GET", f"/count?{self._qs}&where={_up.quote(where)}")["count"]

    def agg(self, group_by, sum="", minmax=""):
        return self._req("GET", f"/agg?{self._qs}&group-by={_up.quote(group_by)}"
                                f"&sum={_up.quote(sum)}&minmax={_up.quote(minmax)}")

    def index(self, field, sums="", kind=""):
        """kind: "" (equality buckets + sum registers) or "range" (sorted projection)."""
        self._req("POST", "/index", {"db": self._db, "coll": self._coll,
                                     "field": field, "sums": sums, "kind": kind})

    def put_many(self, docs):
        """One commit for many docs: dicts (auto id) or (id, dict) pairs. -> {ops, ids}"""
        lines = []
        for d in docs:
            if isinstance(d, tuple):
                lines.append(d[0] + "\t" + _json.dumps(d[1], separators=(",", ":")))
            else:
                lines.append(_json.dumps(d, separators=(",", ":")))
        return self.bulk(lines)

    def del_many(self, ids):
        return self.bulk(["-\t" + i for i in ids])

    def bulk(self, lines):
        """Raw bulk lines: '{...}' put auto-id · 'id\\t{...}' put · '-\\tid' del.
        All-or-nothing, one WAL commit."""
        return self._req("POST", f"/bulk?{self._qs}", raw_body="\n".join(lines), ctype="text/plain")

    def export(self, where=""):
        return self._req("GET", f"/export?{self._qs}&where={_up.quote(where)}")

    def collections(self):
        return self._req("GET", f"/collections?db={_up.quote(self._db)}")["collections"]

    def dbs(self):
        return self._req("GET", "/dbs")["dbs"]

    def usage(self):
        return self._req("GET", "/usage")

    def stats(self):
        return self._req("GET", f"/stats?{self._qs}")


def signup(url, peage_wallet, name=""):
    """Self-serve signup on a hosted instance: a peage wallet is the only credential.
    -> {tenant, token, pricing, how}"""
    req = _rq.Request(url.rstrip("/") + "/tenants",
                      data=_json.dumps({"name": name}).encode(), method="POST",
                      headers={"content-type": "application/json", "X-Peage-Wallet": peage_wallet})
    try:
        with _rq.urlopen(req, timeout=30) as resp:
            env = _json.loads(resp.read().decode())
    except _er.HTTPError as e:
        env = _json.loads(e.read().decode())
    if not env.get("ok"):
        err = env.get("error") or {}
        raise GrangeError(err.get("type", "protocol"), err.get("message", ""))
    return env["data"]
