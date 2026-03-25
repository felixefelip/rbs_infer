DUMMY_DIR = spec/dummy
ROOT_DIR = $(shell pwd)
RBS_INFER = bundle exec ruby -I$(ROOT_DIR)/lib $(ROOT_DIR)/bin/rbs_infer
OUTPUT_DIR = sig/rbs_infer

.PHONY: rbs rbs-controllers rbs-models rbs-services rbs-rails-custom rbs-erb test steep

## Gerar RBS para todo o app/ do dummy
rbs_infer:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/ --output --output-dir $(OUTPUT_DIR)

rbs_models:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/models/ --output --output-dir $(OUTPUT_DIR)

rbs_services:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/services/ --output --output-dir $(OUTPUT_DIR)

rbs_helpers:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/helpers/ --output --output-dir $(OUTPUT_DIR)

rbs_rails_custom:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/custom_generator'; RbsInfer::Extensions::Rails::CustomGenerator.new(output_dir: 'sig/rbs_rails_custom').generate_all"

rbs_infer_enumerize:
	cd $(DUMMY_DIR) && bundle exec rake rbs_infer:enumerize:all

rbs_rails_generator:
	cd $(DUMMY_DIR) && rake rbs_rails:all

rbs_infer_erb:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/erb_convention_generator'; RbsInfer::Extensions::Rails::ErbConventionGenerator.new(app_dir: '.', output_dir: 'sig/rbs_infer_erb', source_files: Dir['app/**/*.rb']).generate_all"

rbs_generators_all:
	make rbs_rails_generator
	make rbs_rails_custom
	make rbs_infer_enumerize
	make rbs_infer_erb

## Gerar RBS apenas para arquivo específico passado como argumento


## Rodar testes
test:
	bundle exec rspec

## Análise de tipos com Steep no dummy
steep:
	cd $(DUMMY_DIR) && STEEP_ERB_CONVENTION=1 bundle exec steep check
