.PHONY: build test dev screenshots

build:
	swift build

test:
	./scripts/test.sh

dev:
	./scripts/dev.sh

screenshots:
	./scripts/screenshots.sh
