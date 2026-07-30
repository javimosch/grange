BIN = grange
SRCS = framework/flags.src framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/bench.src src/tenant.src src/landing.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src src/cli.src

build:
	machin encode $(SRCS) > $(BIN).mfl
	machin build $(BIN).mfl -o $(BIN)

check:
	machin check $(SRCS)

test:
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/engine_test.src | tail -1
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/unit_query_test.src | tail -1
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/unit_index_test.src | tail -1
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/unit_cold_test.src | tail -1
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/unit_tenant_test.src | tail -1
	@machin test framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/tenant.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src tests/diff_cold_test.src | tail -1

bench: build
	rm -rf /tmp/grange-bench
	./$(BIN) bench --n 100000 --vs-sqlite

guide: build
	./scripts/guide_test.sh ./$(BIN)

routes: build
	./scripts/routes_test.sh ./$(BIN)

durability: build
	./scripts/durability_test.sh ./$(BIN)

isolation: build
	./scripts/isolation_test.sh ./$(BIN)

embed:
	./scripts/embed_test.sh

backup: build
	./scripts/backup_test.sh ./$(BIN)

replicas: build
	./scripts/replicas_test.sh ./$(BIN)

retention: build
	./scripts/retention_test.sh ./$(BIN)

indexbuild: build
	./scripts/indexbuild_test.sh ./$(BIN)

sdkversion:
	./scripts/sdk_version_test.sh

projection: build
	./scripts/projection_test.sh ./$(BIN)

pagination: build
	./scripts/pagination_test.sh ./$(BIN)

soak: build
	./scripts/soak_test.sh ./$(BIN)

crash: build
	./scripts/crash_test.sh ./$(BIN) 5
	./scripts/crash_cold_test.sh ./$(BIN) 3

fuzz: build
	./scripts/fuzz_cold.sh 1200 6
	python3 scripts/fuzz_replica.py 150 3

verify: check test embed guide sdkversion backup projection routes durability isolation pagination indexbuild retention replicas soak bench crash fuzz

clean:
	rm -f $(BIN) $(BIN).mfl

.PHONY: build check test embed guide sdkversion backup projection routes durability isolation pagination indexbuild retention replicas soak bench crash verify clean
