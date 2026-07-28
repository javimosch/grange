// Package grange is a client for the grange document database HTTP API —
// the hosted instance (https://grange.intrane.fr/llms.txt) or any `grange serve`.
//
//	g := grange.New("https://grange.intrane.fr", "gt_...")
//	leads := g.DB("mydb").Coll("leads")
//	id, _ := leads.Put("", map[string]any{"co": "acme", "score": 9})
//	var doc map[string]any
//	found, _ := leads.Get(id, &doc)
//	n, _ := leads.Count("co=acme")
package grange

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Client talks to one grange server with one token.
type Client struct {
	Base  string
	Token string
	HTTP  *http.Client
	db    string
	coll  string
}

// New returns a client scoped to db "default", collection "default".
func New(base, token string) *Client {
	return &Client{Base: base, Token: token, HTTP: &http.Client{Timeout: 30 * time.Second}, db: "default", coll: "default"}
}

// DB returns a copy of the client scoped to another database.
func (c *Client) DB(db string) *Client { d := *c; d.db = db; return &d }

// Coll returns a copy of the client scoped to another collection.
func (c *Client) Coll(coll string) *Client { d := *c; d.coll = coll; return &d }

type envelope struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

func (c *Client) do(method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.Base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("grange: bad response (%d): %s", resp.StatusCode, raw)
	}
	if !env.OK {
		if env.Error != nil {
			return fmt.Errorf("grange: %s: %s", env.Error.Type, env.Error.Message)
		}
		return fmt.Errorf("grange: request failed (%d)", resp.StatusCode)
	}
	if out != nil {
		return json.Unmarshal(env.Data, out)
	}
	return nil
}

func (c *Client) qs() string {
	return "coll=" + url.QueryEscape(c.coll) + "&db=" + url.QueryEscape(c.db)
}

// Put stores doc (any JSON-marshalable value) under id; empty id auto-generates.
// Returns the id.
func (c *Client) Put(id string, doc any) (string, error) {
	body := map[string]any{"db": c.db, "coll": c.coll, "doc": doc}
	if id != "" {
		body["id"] = id
	}
	var out struct {
		ID string `json:"id"`
	}
	if err := c.do("POST", "/put", body, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

// Get unmarshals the document into out. Returns false if the id doesn't exist.
func (c *Client) Get(id string, out any) (bool, error) {
	var wrap struct {
		Doc json.RawMessage `json:"doc"`
	}
	err := c.do("GET", "/get?"+c.qs()+"&id="+url.QueryEscape(id), nil, &wrap)
	if err != nil {
		if e, ok := err.(interface{ Error() string }); ok && bytes.Contains([]byte(e.Error()), []byte("not-found")) {
			return false, nil
		}
		return false, err
	}
	if out != nil {
		return true, json.Unmarshal(wrap.Doc, out)
	}
	return true, nil
}

// Del deletes a document.
func (c *Client) Del(id string) error {
	return c.do("POST", "/del", map[string]any{"db": c.db, "coll": c.coll, "id": id}, nil)
}

// Item is one find result.
type Item struct {
	ID  string          `json:"id"`
	Doc json.RawMessage `json:"doc"`
}

// FindResult is the result of a Find.
type FindResult struct {
	Count int    `json:"count"`
	Mode  string `json:"mode"`
	Items []Item `json:"items"`
}

// Find queries with a where filter ("f=v,f2>=v2", ANDed; "" = all). limit 0 = server default.
func (c *Client) Find(where string, limit int) (*FindResult, error) {
	var out FindResult
	err := c.do("GET", fmt.Sprintf("/find?%s&where=%s&limit=%d", c.qs(), url.QueryEscape(where), limit), nil, &out)
	return &out, err
}

// FindOrdered returns the first (or, with desc, the last) limit documents BY
// order, which must be a --range-indexed field. Without an order a limit
// returns an arbitrary subset rather than the top/latest N.
func (c *Client) FindOrdered(where string, limit int, order string, desc bool) (*FindResult, error) {
	var out FindResult
	q := fmt.Sprintf("/find?%s&where=%s&limit=%d&order=%s", c.qs(), url.QueryEscape(where), limit, url.QueryEscape(order))
	if desc {
		q += "&desc=1"
	}
	err := c.do("GET", q, nil, &out)
	return &out, err
}

// Count counts matches ("" = all docs). O(1) on indexed equality / range fields.
func (c *Client) Count(where string) (int, error) {
	var out struct {
		Count int `json:"count"`
	}
	err := c.do("GET", "/count?"+c.qs()+"&where="+url.QueryEscape(where), nil, &out)
	return out.Count, err
}

// Agg groups by a field with optional comma-separated sum fields.
// Returns the raw data JSON ({"group_by":...,"groups":[...]}).
func (c *Client) Agg(groupBy, sum string) (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do("GET", "/agg?"+c.qs()+"&group-by="+url.QueryEscape(groupBy)+"&sum="+url.QueryEscape(sum), nil, &out)
	return out, err
}

// Index declares an index. kind: "" (equality + sum registers) or "range".
func (c *Client) Index(field, sums, kind string) error {
	return c.do("POST", "/index", map[string]any{"db": c.db, "coll": c.coll, "field": field, "sums": sums, "kind": kind}, nil)
}

// BulkResult reports a bulk apply.
type BulkResult struct {
	Ops int      `json:"ops"`
	IDs []string `json:"ids"`
}

// PutMany stores many docs in ONE commit (auto ids). For ids or deletes, use Bulk.
func (c *Client) PutMany(docs []any) (*BulkResult, error) {
	lines := make([]string, 0, len(docs))
	for _, d := range docs {
		b, err := json.Marshal(d)
		if err != nil {
			return nil, err
		}
		lines = append(lines, string(b))
	}
	return c.Bulk(lines)
}

// Bulk applies newline-delimited ops in one commit:
// "{...}" put auto-id · "<id>\t{...}" put · "-\t<id>" delete.
func (c *Client) Bulk(lines []string) (*BulkResult, error) {
	// server-side cost per batch grows superlinearly with batch size, so chunk
	// here instead of expecting callers to know that
	const limit = 10000
	if len(lines) > limit {
		out := &BulkResult{}
		for i := 0; i < len(lines); i += limit {
			end := i + limit
			if end > len(lines) {
				end = len(lines)
			}
			r, err := c.Bulk(lines[i:end])
			if err != nil {
				return out, err
			}
			out.Ops += r.Ops
			if len(out.IDs) < 100 {
				out.IDs = append(out.IDs, r.IDs...)
			}
		}
		return out, nil
	}
	body := bytes.NewReader([]byte(joinLines(lines)))
	req, err := http.NewRequest("POST", c.Base+"/bulk?"+c.qs(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("grange: bad response (%d): %s", resp.StatusCode, raw)
	}
	if !env.OK {
		if env.Error != nil {
			return nil, fmt.Errorf("grange: %s: %s", env.Error.Type, env.Error.Message)
		}
		return nil, fmt.Errorf("grange: request failed (%d)", resp.StatusCode)
	}
	var out BulkResult
	return &out, json.Unmarshal(env.Data, &out)
}

func joinLines(lines []string) string {
	out := ""
	for i, l := range lines {
		if i > 0 {
			out += "\n"
		}
		out += l
	}
	return out
}

// Watch long-polls until the collection changes past since (or timeout seconds).
// Returns {"seq":..,"resync":..,"changes":[{seq,op,id}]} as raw JSON.
func (c *Client) Watch(since, timeoutSec int) (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do("GET", fmt.Sprintf("/watch?%s&since=%d&timeout=%d", c.qs(), since, timeoutSec), nil, &out)
	return out, err
}

// Cold converts this collection to disk-resident storage. Irreversible.
func (c *Client) Cold() error {
	return c.do("POST", "/cold", map[string]any{"db": c.db, "coll": c.coll}, nil)
}

// Compact folds WAL chunks (or cold runs) into a fresh generation.
func (c *Client) Compact() error {
	return c.do("POST", "/compact", map[string]any{"db": c.db, "coll": c.coll}, nil)
}

// Verify runs an integrity check (checksums, manifests vs pages, declared
// indexes). It returns an error when the collection is damaged.
func (c *Client) Verify() (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do("GET", "/verify?"+c.qs(), nil, &out)
	return out, err
}

// Export dumps the collection. Empty where means everything.
func (c *Client) Export(where string) (*FindResult, error) {
	var out FindResult
	err := c.do("GET", "/export?"+c.qs()+"&where="+url.QueryEscape(where), nil, &out)
	return &out, err
}

// ExportLines dumps the collection as NDJSON "<id>\t<doc>" text, which can be
// piped straight into another grange's Bulk.
func (c *Client) ExportLines() (string, error) {
	req, err := http.NewRequest("GET", c.Base+"/export?"+c.qs()+"&format=lines", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return string(b), err
}

// Usage returns the tenant's storage/billing view as raw JSON.
func (c *Client) Usage() (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do("GET", "/usage", nil, &out)
	return out, err
}
