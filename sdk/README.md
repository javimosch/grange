# grange client SDKs

Thin clients for the grange HTTP API — the hosted instance
(https://grange.intrane.fr/llms.txt) or any `grange serve`. All three expose
the same surface: `put get del find count agg index collections dbs usage`,
scoped by database + collection (`db("crm").coll("leads")` style).

| SDK | Install | Entry |
|---|---|---|
| **Node.js** (>=18, zero deps) | `npm install grange-db` | `const { Grange, signup } = require('grange-db')` |
| **Go** | `go get github.com/javimosch/grange/sdk/go` | `grange.New(url, token)` |
| **machin (MFL)** | compose `sdk/machin/grange_client.src` | `grange_client(url, token)` |

Each file's header comment is the usage example; the wire contract is
`/llms.txt` on any grange server. Signup for the hosted instance is self-serve
with a [peage](https://peage.intrane.fr) wallet (`signup()` in the Node SDK, or
one curl — see /llms.txt).
