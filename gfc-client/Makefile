GO ?= go
GOOS ?= linux
GOARCH ?= amd64
CGO_ENABLED ?= 0
LDFLAGS ?= -s -w

.PHONY: build-openwrt pack-immortalwrt
build-openwrt:
	mkdir -p bin
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/gfc-api ./cmd/gfc-api
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/gfc-agent ./cmd/gfc-agent
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/gfc-bootstrap ./cmd/gfc-bootstrap

pack-immortalwrt:
	GOARCH=$(GOARCH) GOARM=$(GOARM) CGO_ENABLED=$(CGO_ENABLED) bash deploy/immortalwrt/pack-runtime.sh
