BINARY := appcorectl

.PHONY: build test lint vuln package ci

build:
	cargo build --release --locked
	mkdir -p bin
	install -m 0755 target/release/$(BINARY) bin/$(BINARY)

test:
	cargo test --locked

lint:
	cargo fmt --check
	cargo clippy --locked --all-targets -- -D warnings

vuln:
	cargo audit

package:
	./scripts/package.sh

ci: test lint vuln
