-include .env
.EXPORT_ALL_VARIABLES:
MAKEFLAGS += --no-print-directory

NETWORK ?= avalanche-mainnet


install:
	yarn
	foundryup
	forge install

contracts:
	FOUNDRY_TEST=/dev/null forge build --via-ir --sizes --force


test:
	forge test -vvv

test-unit:
	@FOUNDRY_PROFILE=test-unit make test

test-internal:
	@FOUNDRY_PROFILE=test-internal make test

test-integration:
	@FOUNDRY_PROFILE=test-integration make test


test-%:
	@FOUNDRY_MATCH_TEST=$* make test

test-unit-%:
	@FOUNDRY_MATCH_TEST=$* make test-unit

test-internal-%:
	@FOUNDRY_MATCH_TEST=$* make test-internal

test-integration-%:
	@FOUNDRY_MATCH_TEST=$* make test-integration


coverage:
	forge coverage --report lcov
	lcov --remove lcov.info -o lcov.info "test/*"

lcov-html:
	@echo Transforming the lcov coverage report into html
	genhtml lcov.info -o coverage

gas-report:
	forge test --gas-report


.PHONY: contracts test coverage