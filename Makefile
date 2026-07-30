BIN = grange
SRCS = framework/flags.src framework/machweb.src src/recfile.src src/engine.src src/registry.src src/cold.src src/coldbulk.src src/coldindex.src src/coldquery.src src/coldrange.src src/coldsort.src src/index.src src/range.src src/qcost.src src/project.src src/query.src src/order.src src/verify.src src/ready.src src/watch.src src/bench.src src/tenant.src src/landing.src src/servemeta.src src/servebulk.src src/serveread.src src/serve.src src/cli.src

build:
	machin encode $(SRCS) > $(BIN).mfl
	machin build $(BIN).mfl -o $(BIN)

# The RELEASE artifact is static, and it is a different binary from `make build`.
#
# `make build` links against the host's libssl, libcrypto, libsqlite3 and glibc,
# because that is machin's default. That binary was published for every release
# up to v0.13.0 under a README promising "statically linked, no runtime
# dependencies, no glibc floor" — it required glibc 2.34+ and SQLite at runtime,
# so it would not start on Debian 11, Ubuntu 20.04, RHEL 8, Alpine, or a slim
# container. Nobody hit it because nobody had downloaded it.
#
# 7.5 MB instead of 321 KB. Insert throughput is unchanged (104-130k/s either
# way, measured three times alternating).
release: 
	machin encode $(SRCS) > $(BIN).mfl
	machin build $(BIN).mfl -o $(BIN)-linux-x86_64 --static
	@file $(BIN)-linux-x86_64 | grep -q "statically linked" \
	  || { echo "release binary is NOT static — refusing"; exit 1; }
	@ldd $(BIN)-linux-x86_64 2>&1 | grep -q "not a dynamic executable" \
	  || { echo "release binary has dynamic dependencies — refusing"; exit 1; }
	@./$(BIN)-linux-x86_64 guide >/dev/null || { echo "release binary does not run"; exit 1; }
	@echo "release binary ok: $$(ls -l $(BIN)-linux-x86_64 | awk '{print $$5}') bytes, static"

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

journey: build
	./scripts/journey_test.sh --bin ./$(BIN)

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

inclause: build
	./scripts/inclause_test.sh

doccoverage: build
	./scripts/doccoverage_test.sh

# NOT in `verify`: it tests the PUBLISHED release, which by definition does not
# exist yet while you are verifying the thing you are about to publish. Run it
# after a release, which is when its answer is meaningful.
stranger:
	./scripts/stranger_test.sh

soak: build
	./scripts/soak_test.sh ./$(BIN)

crash: build
	./scripts/crash_test.sh ./$(BIN) 5
	./scripts/crash_cold_test.sh ./$(BIN) 3

fuzz: build
	./scripts/fuzz_cold.sh 1200 6
	python3 scripts/fuzz_replica.py 150 3

verify: check test embed guide sdkversion journey backup projection routes durability isolation pagination inclause doccoverage indexbuild retention replicas soak bench crash fuzz

clean:
	rm -f $(BIN) $(BIN).mfl

.PHONY: build release stranger check test embed guide sdkversion journey backup projection routes durability isolation pagination inclause doccoverage indexbuild retention replicas soak bench crash verify clean
