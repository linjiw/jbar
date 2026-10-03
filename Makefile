# JBar — build/install/run helpers. See docs/DESIGN.md for the architecture.
.PHONY: build app install uninstall run test test-release cli cli-package bench clean icon fmt

build:            ## Debug build of the SwiftPM package
	swift build

app:              ## Assemble build/JBar.app (release, signed)
	scripts/build-app.sh

install: ## Build and install to /Applications (no sudo), then launch
	scripts/install.sh

uninstall:        ## Remove JBar.app (add PURGE=1 to also delete config/cache/history)
	scripts/uninstall.sh $(if $(PURGE),--purge,)

run: app          ## Build the app and open it
	open build/JBar.app

test:             ## Run the unit tests (debug)
	swift test

test-release:     ## Run the unit tests with optimisation (enforces perf budgets)
	swift test -c release

cli:              ## Build the standalone agent-friendly CLI (no app bundle)
	swift build -c release --product jbar-cli -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete

cli-package:      ## Stage a Universal 2 CLI archive: make cli-package OUT=/absolute/new/temp-dir
	scripts/build-cli.sh "$(OUT)"

bench: app        ## Headless index benchmark (items, time, RSS)
	build/JBar.app/Contents/MacOS/JBar --bench-index

icon:             ## Regenerate Resources/AppIcon.icns
	scripts/make-icns.sh

clean:            ## Remove build products
	rm -rf .build build .build-*

help:             ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'
