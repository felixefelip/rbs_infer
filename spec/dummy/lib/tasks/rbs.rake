begin
  require 'rbs_rails/rake_task'

  RbsRails::RakeTask.new do |task|
    # If you want to change the rake task namespace, comment in it.
    # default: :rbs_rails
    # task.name = :cool_rbs_rails
  end
rescue LoadError
  # failed to load rbs_rails. Skip to load rbs_rails tasks.
end
