# grange-db (Python)

Zero-dependency client for the [grange](https://github.com/javimosch/grange)
document database — the hosted instance (https://grange.intrane.fr/llms.txt)
or any `grange serve`.

```python
from grange_db import Grange
g = Grange("https://grange.intrane.fr", "gt_...")
leads = g.db("crm").coll("leads")
doc_id = leads.put({"co": "acme", "score": 9})
leads.index("score", kind="range")
print(leads.count("score>=5"))
leads.put_many([{"co": "globex"}, ("l2", {"co": "initech"})])   # one commit
```

Signup is self-serve with a [peage](https://peage.intrane.fr) wallet:
`grange_db.signup(url, "pw_...")`. MIT.
