BIN = grange
SRCS = framework/flags.src framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/bench.src src/tenant.src src/landing.src src/serve.src src/cli.src

build:
	machin encode $(SRCS) > $(BIN).mfl
	machin build $(BIN).mfl -o $(BIN)

check:
	machin check $(SRCS)

test:
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/engine_test.src | tail -1
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/unit_query_test.src | tail -1
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/unit_index_test.src | tail -1
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/unit_cold_test.src | tail -1
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/unit_tenant_test.src | tail -1
	@machin test framework/machweb.src src/engine.src src/registry.src src/cold.src src/coldindex.src src/coldrange.src src/index.src src/range.src src/query.src src/verify.src src/watch.src src/tenant.src src/serve.src tests/diff_cold_test.src | tail -1

bench: build
	rm -rf /tmp/grange-bench
	./$(BIN) bench --n 100000 --vs-sqlite

crash: build
	./scripts/crash_test.sh ./$(BIN) 5
	./scripts/crash_cold_test.sh ./$(BIN) 3

fuzz: build
	./scripts/fuzz_cold.sh 1200 6
	python3 scripts/fuzz_replica.py 150 3

verify: check test bench crash fuzz

clean:
	rm -f $(BIN) $(BIN).mfl

.PHONY: build check test bench crash verify clean
