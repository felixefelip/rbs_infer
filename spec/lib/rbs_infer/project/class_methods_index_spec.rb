require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Project::ClassMethodsIndex do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_file(name, content)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def index_for(*files)
    described_class.new(
      file_index: RbsInfer::Project::FileIndex.new(files),
      parse_cache: RbsInfer::Project::ParseCache.new
    )
  end

  it "encontra ClassMethods escrito literalmente" do
    file = write_file("post/taggable.rb", <<~RUBY)
      module Post::Taggable
        module ClassMethods
          def default_tag_names = []
        end
      end
    RUBY

    expect(index_for(file).has?("Post::Taggable", enclosing: "Post")).to eq(true)
  end

  # A `class_methods do` block is NOT one of them, and no longer needs to be:
  # nothing desugars it into a nested module any more. The transcribed
  # `ActiveSupport::Concern` says what the DSL runs, the replay chain reads it,
  # and the `extend` reaches the host from the concern's own `append_features`
  # rather than from this index's convention (felixefelip/rbs_infer#268).
  it "não encontra nada num bloco class_methods, que não declara módulo nenhum" do
    file = write_file("post/taggable.rb", <<~RUBY)
      module Post::Taggable
        extend ActiveSupport::Concern

        class_methods do
          def default_tag_names = []
        end
      end
    RUBY

    expect(index_for(file).has?("Post::Taggable", enclosing: "Post")).to eq(false)
  end

  # The Fizzy shape: `include Params` written inside `class Filter` means
  # `Filter::Params`, never top-level `Params` (felixefelip/rbs_infer#188).
  it "resolve o nome do módulo no escopo léxico do includer" do
    file = write_file("filter/params.rb", <<~RUBY)
      module Filter::Params
        module ClassMethods
          def find_by_params(params) = nil
        end
      end
    RUBY

    index = index_for(file)

    expect(index.has?("Params", enclosing: "Filter")).to eq(true)
    expect(index.has?("Params", enclosing: nil)).to eq(false)
  end

  it "encontra ClassMethods sob namespace aninhado escrito por extenso" do
    file = write_file("filter/params.rb", <<~RUBY)
      module Filter
        module Params
          module ClassMethods
            def find_by_params(params) = nil
          end
        end
      end
    RUBY

    expect(index_for(file).has?("Params", enclosing: "Filter")).to eq(true)
  end

  it "retorna false para módulo sem ClassMethods" do
    file = write_file("post/notifiable.rb", <<~RUBY)
      module Post::Notifiable
        def notify = nil
      end
    RUBY

    expect(index_for(file).has?("Post::Notifiable", enclosing: "Post")).to eq(false)
  end

  # `extend` takes a module: a class of that name could not be extended, so it
  # must not produce the mixin.
  it "retorna false quando ClassMethods é uma classe, não um módulo" do
    file = write_file("post/taggable.rb", <<~RUBY)
      module Post::Taggable
        class ClassMethods
        end
      end
    RUBY

    expect(index_for(file).has?("Post::Taggable", enclosing: "Post")).to eq(false)
  end

  it "retorna false para módulo que o projeto não declara" do
    expect(index_for.has?("TotallyFakeModule::DoesNotExist", enclosing: nil)).to eq(false)
  end

  # A path suffix is not unique, so a file matching by suffix alone must not
  # answer for a module it does not declare (felixefelip/rbs_infer#185).
  it "ignora arquivo que casa por sufixo mas declara outro módulo" do
    file = write_file("other/params.rb", <<~RUBY)
      module Other::Params
        module ClassMethods
        end
      end
    RUBY

    expect(index_for(file).has?("Params", enclosing: "Filter")).to eq(false)
  end
end
