BIN = grange
SRCS = framework/flags.src framework/machweb.src src/engine.src src/index.src src/range.src src/query.src src/bench.src src/serve.src src/cli.src

build:
	machin encode $(SRCS) > $(BIN).mfl
	machin build $(BIN).mfl -o $(BIN)

check:
	machin check $(SRCS)

test:
	machin test src/engine.src src/index.src src/range.src src/query.src tests/engine_test.src

bench: build
	rm -rf /tmp/grange-bench
	./$(BIN) bench --n 100000 --vs-sqlite

crash: build
	./scripts/crash_test.sh ./$(BIN) 5

verify: check test bench crash

clean:
	rm -f $(BIN) $(BIN).mfl

.PHONY: build check test bench crash verify clean
