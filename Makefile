DUMMY_DIR = spec/dummy
ROOT_DIR = $(shell pwd)
RBS_INFER = bundle exec ruby -I$(ROOT_DIR)/lib $(ROOT_DIR)/bin/rbs_infer
OUTPUT_DIR = sig/rbs_infer

.PHONY: rbs rbs-controllers rbs-models rbs-services rbs-rails-custom rbs-erb test steep

## Gerar RBS para todo o app/ do dummy
rbs:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/ --output --output-dir $(OUTPUT_DIR)

rbs-models:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/models/ --output --output-dir $(OUTPUT_DIR)

rbs-services:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/services/ --output --output-dir $(OUTPUT_DIR)

rbs-helpers:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/helpers/ --output --output-dir $(OUTPUT_DIR)

rbs-rails-custom:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/custom_generator'; RbsInfer::Extensions::Rails::CustomGenerator.new(output_dir: 'sig/rbs_rails_custom').generate_all"

rbs-erb:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/erb_convention_generator'; RbsInfer::Extensions::Rails::ErbConventionGenerator.new(app_dir: '.', output_dir: 'sig/rbs_infer_erb', source_files: Dir['app/**/*.rb']).generate_all"

## Gerar RBS apenas para arquivo específico passado como argumento


## Rodar testes
test:
	bundle exec rspec

## Análise de tipos com Steep no dummy
steep:
	cd $(DUMMY_DIR) && STEEP_ERB_CONVENTION=1 bundle exec steep check
