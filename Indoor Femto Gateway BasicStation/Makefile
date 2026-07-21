# MT7620 (Gemtek/Browan Indoor Femto) is little-endian MIPS32 with no FPU, so
# the target is mipsle + softfloat. CGO off + static keeps the binary portable
# across the gateway's old uClibc userland.
BIN ?= bin/pktfwd-station-bridge
GOFLAGS = -trimpath -ldflags=-s -ldflags=-w

.PHONY: build build-host test vet clean

build: ## cross-compile for the gateway (mipsle, softfloat, static)
	CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build $(GOFLAGS) -o $(BIN) ./cmd/bridge
	@echo "built $(BIN) ($$(file -b $(BIN) 2>/dev/null || echo mipsle))"

build-host: ## build for the local machine (for tests / cupsboot)
	go build $(GOFLAGS) -o bin/pktfwd-station-bridge.host ./cmd/bridge

test:
	go test ./...

vet:
	go vet ./...

clean:
	rm -rf bin
