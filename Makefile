EMACS ?= emacs
ELISP_FILES := refbox-rpc.el refbox.el refbox-org.el refbox-latex.el refbox-markdown.el refbox-embark.el
ELISP_TEST_FILES := tests/test-refbox.el tests/test-refbox-org.el tests/test-refbox-latex.el tests/test-refbox-markdown.el tests/test-refbox-embark.el
ELISP_ELC_FILES := $(ELISP_FILES:.el=.elc) $(ELISP_TEST_FILES:.el=.elc)

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
	$(EMACS) -Q --batch -L . -l refbox.el -l tests/test-refbox.el -f ert-run-tests-batch-and-exit

.PHONY: byte-compile
byte-compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(ELISP_FILES) $(ELISP_TEST_FILES)
	@rm -f $(ELISP_ELC_FILES)

.PHONY: test
test:
	$(MAKE) fmt-check
	$(MAKE) clippy
	$(MAKE) test-rust
	$(MAKE) test-elisp
	$(MAKE) byte-compile

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
