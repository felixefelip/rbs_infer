DUMMY_DIR = spec/dummy
ROOT_DIR = $(shell pwd)
RBS_INFER = ruby -I$(ROOT_DIR)/lib $(ROOT_DIR)/bin/rbs_infer
OUTPUT_DIR = sig/rbs_infer

.PHONY: rbs rbs-controllers rbs-models rbs-services test

## Gerar RBS para todo o app/ do dummy
rbs:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/ --output --output-dir $(OUTPUT_DIR)

## Rodar testes
test:
	bundle exec rspec
