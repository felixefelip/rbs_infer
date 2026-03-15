require "tmpdir"
require "fileutils"

module TempFileHelpers
  def with_temp_files(files, &block)
    Dir.mktmpdir do |dir|
      paths = files.map do |rel_path, content|
        path = File.join(dir, rel_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        path
      end
      block.call(dir, paths)
    end
  end
end
