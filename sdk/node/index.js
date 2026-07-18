// grange client SDK for Node.js (>=18, built-in fetch) — zero dependencies.
// Works against the hosted instance (https://grange.intrane.fr/llms.txt) or
// any `grange serve`.
//
//   const { Grange } = require('grange-db');
//   const g = new Grange({ url: 'https://grange.intrane.fr', token: 'gt_...' });
//   const leads = g.db('mydb').coll('leads');
//   const { id } = await leads.put({ co: 'acme', score: 9 });
//   const doc = await leads.get(id);                  // null if missing
//   const { count, items } = await leads.find('score>=5', { limit: 50 });

class GrangeError extends Error {
  constructor(type, message, status) {
    super(`grange: ${type}: ${message}`);
    this.type = type;
    this.status = status;
  }
}

class Grange {
  constructor({ url, token, db = 'default', coll = 'default' } = {}) {
    if (!url || !token) throw new Error('grange: url and token are required');
    this.url = url.replace(/\/$/, '');
    this.token = token;
    this._db = db;
    this._coll = coll;
  }

  db(name) { return new Grange({ url: this.url, token: this.token, db: name, coll: this._coll }); }
  coll(name) { return new Grange({ url: this.url, token: this.token, db: this._db, coll: name }); }

  get _qs() {
    return `coll=${encodeURIComponent(this._coll)}&db=${encodeURIComponent(this._db)}`;
  }

  async _req(method, path, body) {
    const res = await fetch(this.url + path, {
      method,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${this.token}` },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const env = await res.json().catch(() => null);
    if (!env || env.ok !== true) {
      const err = env && env.error ? env.error : { type: 'protocol', message: `HTTP ${res.status}` };
      throw new GrangeError(err.type, err.message, res.status);
    }
    return env.data;
  }

  async put(doc, id) {
    const body = { db: this._db, coll: this._coll, doc };
    if (id) body.id = id;
    return this._req('POST', '/put', body); // -> { id }
  }

  async get(id) {
    try {
      const d = await this._req('GET', `/get?${this._qs}&id=${encodeURIComponent(id)}`);
      return d.doc;
    } catch (e) {
      if (e.type === 'not-found') return null;
      throw e;
    }
  }

  async del(id) {
    return this._req('POST', '/del', { db: this._db, coll: this._coll, id });
  }

  // where: "f=v,f2>=v2" (ANDed; = > < >= <=). Returns { count, mode, items: [{id, doc}] }.
  async find(where = '', { limit = 100 } = {}) {
    return this._req('GET', `/find?${this._qs}&where=${encodeURIComponent(where)}&limit=${limit}`);
  }

  async count(where = '') {
    const d = await this._req('GET', `/count?${this._qs}&where=${encodeURIComponent(where)}`);
    return d.count;
  }

  // -> { group_by, mode, groups: [{value, count, sum_<f>, avg_<f>}] }
  async agg(groupBy, { sum = '', minmax = '' } = {}) {
    return this._req('GET', `/agg?${this._qs}&group-by=${encodeURIComponent(groupBy)}&sum=${encodeURIComponent(sum)}&minmax=${encodeURIComponent(minmax)}`);
  }

  // kind: '' (equality buckets + sum registers) or 'range' (sorted projection)
  async index(field, { sums = '', kind = '' } = {}) {
    return this._req('POST', '/index', { db: this._db, coll: this._coll, field, sums, kind });
  }

  async collections() { return (await this._req('GET', `/collections?db=${encodeURIComponent(this._db)}`)).collections; }
  async dbs() { return (await this._req('GET', '/dbs')).dbs; }
  async usage() { return this._req('GET', '/usage'); }
  async stats() { return this._req('GET', `/stats?${this._qs}`); }
}

// Self-serve signup on a hosted instance: a peage wallet is the only credential.
async function signup(url, peageWallet, name = '') {
  const res = await fetch(url.replace(/\/$/, '') + '/tenants', {
    method: 'POST',
    headers: { 'X-Peage-Wallet': peageWallet, 'content-type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  const env = await res.json();
  if (!env.ok) throw new GrangeError(env.error.type, env.error.message, res.status);
  return env.data; // { tenant, token, pricing, how }
}

module.exports = { Grange, GrangeError, signup };
