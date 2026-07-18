const { Grange } = require('/home/jarancibia/ai/grange/sdk/node');
(async () => {
  const g = new Grange({ url: 'http://localhost:4482', token: 'gt_18017a66b3503f9d2bce3d676f32feea' }).db('perf').coll('docs');
  // atomicity: batch with a bad line applies nothing
  try { await g.bulk(['{"a":1}', 'not-json']); console.log('FAIL: bad batch accepted'); process.exit(1); } catch (e) {}
  if (await g.count('') !== 0) { console.log('FAIL: partial batch leaked'); process.exit(1); }
  console.log('atomicity OK');
  // throughput: 10k docs in batches of 1000 over HTTP
  const t0 = Date.now();
  for (let b = 0; b < 10; b++) {
    const docs = [];
    for (let i = 0; i < 1000; i++) { const n = b * 1000 + i; docs.push([`k${n}`, { i: n, status: n % 3 ? 'a' : 'b', score: n % 1000 }]); }
    await g.putMany(docs);
  }
  const ms = Date.now() - t0;
  const n = await g.count('');
  console.log(`bulk 10k over HTTP: ${ms}ms (${Math.round(10000000 / ms)} docs/s), count=${n}`);
  // per-request comparison: 100 single puts
  const t1 = Date.now();
  for (let i = 0; i < 100; i++) await g.put({ single: i });
  console.log(`single puts: ${(Date.now() - t1) / 100}ms/doc`);
  const del = await g.delMany(['k0', 'k1']);
  console.log('delMany ops:', del.ops, 'final count:', await g.count(''));
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
