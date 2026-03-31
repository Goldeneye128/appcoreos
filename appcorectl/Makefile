BINARY := appcorectl

.PHONY: build test lint vuln ci

build:
	go build -o bin/$(BINARY) ./cmd/appcorectl

test:
	go test ./...

lint:
	golangci-lint run

vuln:
	govulncheck ./...

ci: test lint vuln
