DUMMY_DIR = spec/dummy
ROOT_DIR = $(shell pwd)
RBS_INFER = bundle exec ruby -I$(ROOT_DIR)/lib $(ROOT_DIR)/bin/rbs_infer
OUTPUT_DIR = sig/rbs_infer

.PHONY: rbs rbs-controllers rbs-models rbs-services test steep

## Gerar RBS para todo o app/ do dummy
rbs:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/ --output --output-dir $(OUTPUT_DIR)

rbs-models:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/models/ --output --output-dir $(OUTPUT_DIR)

rbs-services:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/services/tag_destroy.rb --output --output-dir $(OUTPUT_DIR)

## Gerar RBS apenas para arquivo específico passado como argumento


## Rodar testes
test:
	bundle exec rspec

## Análise de tipos com Steep no dummy
steep:
	cd $(DUMMY_DIR) && bundle exec steep check
