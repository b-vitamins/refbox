EMACS ?= emacs

.PHONY: fmt
fmt:
	cargo fmt --all

.PHONY: test-rust
test-rust:
	cargo test --workspace

.PHONY: test-elisp
test-elisp:
	$(EMACS) -Q --batch -L . -l refbox.el -l tests/test-refbox.el -f ert-run-tests-batch-and-exit

.PHONY: test
test: test-rust test-elisp

.PHONY: clippy
clippy:
	cargo clippy --all-targets --all-features
