# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = true
end

desc "Regenerate the tag, attribute and entity tables and the shortcuts from the C# sources"
task :gen, [:src] do |_, args|
  src = args[:src] || "../z3l.FastHtmlParser/src/z3l.FastHtmlParser"
  ruby "tools/gen.rb", src
end

task default: :test
