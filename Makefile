SHELL  := bash
SCRIPT := build.sh
BATS   := test/bats/bin/bats

.PHONY: all test lint clean install-hooks uninstall-hooks help

all: lint test          ## Default: lint then run all tests

test: $(BATS)           ## Run unit tests
	@$(BATS) --print-output-on-failure test/build.bats

lint:                   ## Check build.sh for bash syntax errors
	@bash -n $(SCRIPT) && printf '[lint] %s: syntax OK\n' $(SCRIPT)

# Install bats-core locally the first time; skipped on subsequent runs.
$(BATS):
	@printf '[setup] Installing bats-core locally into test/bats/ ...\n'
	@git clone --quiet --depth 1 \
		https://github.com/bats-core/bats-core.git test/bats-src
	@test/bats-src/install.sh test/bats >/dev/null
	@rm -rf test/bats-src
	@printf '[setup] Done → %s\n' $(BATS)

install-hooks:          ## Install git pre-commit hook
	@cp hooks/pre-commit $(CURDIR)/.git/hooks/pre-commit
	@chmod +x $(CURDIR)/.git/hooks/pre-commit
	@printf '[hooks] Installed → .git/hooks/pre-commit\n'

uninstall-hooks:        ## Remove git pre-commit hook
	@rm -f $(CURDIR)/.git/hooks/pre-commit
	@printf '[hooks] Removed .git/hooks/pre-commit\n'

clean:                  ## Remove local bats installation
	@rm -rf test/bats test/bats-src
	@printf '[clean] Done\n'

help:                   ## Show this help
	@grep -E '^[a-zA-Z][a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  make %-10s %s\n",$$1,$$2}'
