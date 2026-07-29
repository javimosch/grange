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
__version__ = "0.11.0"


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

    def find(self, where="", limit=100, order="", desc=False, after="", fields=""):
        """where: "f=v,f2>=v2" (ANDed; = > < >= <=). -> {count, mode, items}

        order: a --range-indexed field to order by; desc=True for newest/highest
        first. Without an order a limit returns an arbitrary subset, not the top N.
        """
        q = f"/find?{self._qs}&where={_up.quote(where)}&limit={limit}"
        if order:
            q += f"&order={_up.quote(order)}" + ("&desc=1" if desc else "")
        if after:
            q += f"&after={_up.quote(after)}"
        if fields:
            f = ",".join(fields) if isinstance(fields, (list, tuple)) else fields
            q += f"&fields={_up.quote(f)}"
        return self._req("GET", q)

    def pages(self, where="", limit=100, order="", desc=False, fields=""):
        """Iterate every document of an ordered query, page by page.

        Keyset pagination: `after` is the previous page's `next` cursor, so each
        page costs the same and rows inserted or deleted elsewhere cannot shift
        the position (unlike an offset).
        """
        after = ""
        while True:
            page = self.find(where, limit=limit, order=order, desc=desc, after=after, fields=fields)
            for item in page["items"]:
                yield item
            after = page.get("next", "")
            if not after:
                return

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

    def bulk(self, lines, chunk=10000):
        """Raw bulk lines: '{...}' put auto-id · 'id\\t{...}' put · '-\\tid' del.
        All-or-nothing per chunk, one WAL commit each. Batches are chunked at
        10k lines: server-side cost per batch grows superlinearly with size (a
        25k-line batch retains ~5x more per doc than a 10k one)."""
        if len(lines) > chunk:
            ops, ids = 0, []
            for i in range(0, len(lines), chunk):
                d = self.bulk(lines[i:i + chunk], chunk)
                ops += d["ops"]
                ids.extend(d.get("ids", [])[:max(0, 100 - len(ids))])
            return {"ops": ops, "ids": ids, "chunks": (len(lines) + chunk - 1) // chunk}
        return self._req("POST", f"/bulk?{self._qs}", raw_body="\n".join(lines), ctype="text/plain")

    def watch(self, since=0, timeout=25):
        """Long-poll: blocks server-side until this collection changes past
        `since` (or timeout). -> {seq, resync, changes:[{seq,op,id}]}"""
        old = self.timeout
        self.timeout = timeout + 10
        try:
            return self._req("GET", f"/watch?{self._qs}&since={since}&timeout={timeout}")
        finally:
            self.timeout = old

    def export(self, where=""):
        return self._req("GET", f"/export?{self._qs}&where={_up.quote(where)}")

    def cold(self):
        """Convert this collection to disk-resident (cold) storage. Irreversible."""
        return self._req("POST", "/cold", {"db": self._db, "coll": self._coll})

    def compact(self):
        """Fold WAL chunks (or cold runs) into a fresh generation."""
        return self._req("POST", "/compact", {"db": self._db, "coll": self._coll})

    def verify(self):
        """Integrity check: checksums, manifests vs pages, declared indexes.
        Raises GrangeError('corruption') when the collection is damaged."""
        return self._req("GET", f"/verify?{self._qs}")

    def export(self, where="", format=""):
        """Full dump. format='lines' returns NDJSON '<id>\t<doc>' text (pipe it
        into another grange's bulk); default returns {count, items}."""
        if format == "lines":
            req = _rq.Request(f"{self.url}/export?{self._qs}&format=lines",
                              headers={"authorization": "Bearer " + self.token})
            with _rq.urlopen(req, timeout=self.timeout) as resp:
                return resp.read().decode()
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
