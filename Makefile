DUMMY_DIR = spec/dummy
ROOT_DIR = $(shell pwd)
RBS_INFER = bundle exec rbs_infer
OUTPUT_DIR = sig/rbs_infer

.PHONY: rbs rbs-controllers rbs-models rbs-services rbs-rails-custom rbs-erb test steep

## Gerar RBS para todo o app/ do dummy
rbs_infer:
	cd $(DUMMY_DIR) && $(RBS_INFER) app/ lib/ sig/ --output --output-dir $(OUTPUT_DIR)

rbs_rails_custom:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/custom_generator'; RbsInfer::Extensions::Rails::CustomGenerator.new(output_dir: 'sig/rbs_rails_custom').generate_all"

rbs_infer_enumerize:
	cd $(DUMMY_DIR) && bundle exec rake rbs_infer:enumerize:all

rbs_infer_carrierwave:
	cd $(DUMMY_DIR) && bundle exec rake rbs_infer:carrierwave:all

## Must run AFTER rbs_rails_generator: the devise generator decorates
## `current_<scope>` with `<Model>::Validated` only when that marker is already
## on disk, and rbs_rails is what emits it.
rbs_infer_devise:
	cd $(DUMMY_DIR) && bundle exec rake rbs_infer:devise:all

rbs_collection_update:
	cd $(DUMMY_DIR) && rbs collection update

rbs_rails_generator:
	cd $(DUMMY_DIR) && bundle exec rake rbs_rails:all

rbs_infer_module_self_types:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer/extensions/rails/module_self_type_generator'; RbsInfer::Extensions::Rails::ModuleSelfTypeGenerator.new(app_dir: '.').generate"

rbs_infer_ar_runtime:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer'; require 'rbs_infer/extensions/rails/active_record/runtime_generator'; RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator.new(app_dir: '.').generate"

## `include M` chama `M.included(self)` — a unica coisa que diz qual classe o `base`
## de um hook e. Core: `include` e Ruby puro, nao Rails.
rbs_infer_ruby_runtime:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer'; require 'rbs_infer/project/ruby_runtime_generator'; RbsInfer::Project::RubyRuntimeGenerator.new(app_dir: '.').generate"

rbs_infer_controller_runtime:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer'; require 'rbs_infer/extensions/rails/controllers/runtime_generator'; RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator.new(app_dir: '.').generate"

rbs_infer_actionview_runtime:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer'; require 'rbs_infer/extensions/rails/views/runtime_generator'; RbsInfer::Extensions::Rails::Views::RuntimeGenerator.new(app_dir: '.').generate"

rbs_infer_current_runtime:
	cd $(DUMMY_DIR) && bundle exec ruby -I$(ROOT_DIR)/lib -e "require 'rbs_infer'; require 'rbs_infer/extensions/rails/current_attributes_runtime_generator'; RbsInfer::Extensions::Rails::CurrentAttributesRuntimeGenerator.new(app_dir: '.').generate"

rbs_generators_all:
	make rbs_rails_generator
	make rbs_rails_custom
	make rbs_infer_enumerize
	make rbs_infer_carrierwave
	make rbs_infer_devise
	make rbs_infer_module_self_types
	make rbs_infer_ar_runtime
	make rbs_infer_ruby_runtime
	make rbs_infer_controller_runtime
	make rbs_infer_current_runtime
	make rbs_infer_actionview_runtime

## Gerar RBS apenas para arquivo específico passado como argumento


## Rodar testes
test:
	bundle exec rspec

## Mesma suíte em dois processos concorrentes (~114s -> ~75s).
## Não use para regravar snapshots — bin/rspec-parallel recusa UPDATE_* e
## explica o porquê.
test_parallel:
	./bin/rspec-parallel

## Análise de tipos com Steep no dummy
steep:
	cd $(DUMMY_DIR) && STEEP_ERB_CONVENTION=1 STEEP_MODULE_CONVENTION=1 bundle exec steep check
