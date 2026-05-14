EMACS ?= emacs
BENCH_REPORT_DIR ?= target/refbox-bench
BENCH_RELEASE_DAEMON := target/release/refbox
BENCH_RELEASE_RUNNER := target/release/refbox-bench
ELISP_FILES := refbox-rpc.el refbox.el refbox-org.el refbox-latex.el refbox-markdown.el refbox-embark.el
ELISP_TEST_FILES := tests/test-init.el tests/test-refbox.el tests/test-refbox-org.el tests/test-refbox-latex.el tests/test-refbox-markdown.el tests/test-refbox-embark.el
ELISP_ELC_FILES := $(ELISP_FILES:.el=.elc) $(ELISP_TEST_FILES:.el=.elc)
ELISP_BATCH_ARGS := -Q --batch -L . -l tests/test-init.el

.PHONY: fmt
fmt:
	cargo fmt --all

.PHONY: fmt-check
fmt-check:
	cargo fmt --all -- --check

.PHONY: test-rust
test-rust:
	cargo test --workspace

.PHONY: test-elisp
test-elisp:
	$(EMACS) $(ELISP_BATCH_ARGS) -l refbox.el -l tests/test-refbox.el -f ert-run-tests-batch-and-exit

.PHONY: byte-compile
byte-compile:
	$(EMACS) $(ELISP_BATCH_ARGS) -f batch-byte-compile $(ELISP_FILES) $(ELISP_TEST_FILES)
	@rm -f $(ELISP_ELC_FILES)

.PHONY: test
test:
	$(MAKE) fmt-check
	$(MAKE) clippy
	$(MAKE) test-rust
	$(MAKE) test-elisp
	$(MAKE) byte-compile
	$(MAKE) bench-ci

.PHONY: clippy
clippy:
	cargo clippy --workspace --all-targets

.PHONY: clippy-all-features
clippy-all-features:
	cargo clippy --workspace --all-targets --all-features

.PHONY: build
build:
	cargo build -p refbox

.PHONY: build-bundled-sqlite
build-bundled-sqlite:
	cargo build -p refbox --features bundled-sqlite

.PHONY: release
release:
	cargo build --release -p refbox

.PHONY: release-bundled-sqlite
release-bundled-sqlite:
	cargo build --release -p refbox --features bundled-sqlite

.PHONY: bench-ci
bench-ci:
	mkdir -p "$(BENCH_REPORT_DIR)"
	cargo build -p refbox
	cargo run -p refbox-bench -- --profile ci --emacs "$(EMACS)" --report "$(BENCH_REPORT_DIR)/ci.json"

.PHONY: bench-release
bench-release:
	mkdir -p "$(BENCH_REPORT_DIR)"
	cargo build --release -p refbox -p refbox-bench
	"$(BENCH_RELEASE_RUNNER)" --profile release --emacs "$(EMACS)" --daemon "$(BENCH_RELEASE_DAEMON)" --report "$(BENCH_REPORT_DIR)/release.json"

.PHONY: bench-local
bench-local:
	mkdir -p "$(BENCH_REPORT_DIR)"
	cargo build --release -p refbox -p refbox-bench
	"$(BENCH_RELEASE_RUNNER)" --profile local --emacs "$(EMACS)" --daemon "$(BENCH_RELEASE_DAEMON)" --report "$(BENCH_REPORT_DIR)/local.json"

.PHONY: bench-real
bench-real:
	: "$${REFBOX_BENCH_REAL_ROOT:?set REFBOX_BENCH_REAL_ROOT}"
	: "$${REFBOX_BENCH_REAL_QUERY:?set REFBOX_BENCH_REAL_QUERY}"
	: "$${REFBOX_BENCH_REAL_KEY:?set REFBOX_BENCH_REAL_KEY}"
	mkdir -p "$(BENCH_REPORT_DIR)"
	cargo build --release -p refbox -p refbox-bench
	"$(BENCH_RELEASE_RUNNER)" --profile real --root "$$REFBOX_BENCH_REAL_ROOT" --query "$$REFBOX_BENCH_REAL_QUERY" --key "$$REFBOX_BENCH_REAL_KEY" --emacs "$(EMACS)" --daemon "$(BENCH_RELEASE_DAEMON)" --report "$(BENCH_REPORT_DIR)/real.json"
