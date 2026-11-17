# frozen_string_literal: true

require_relative "lib/fasthtmlparser/version"

Gem::Specification.new do |spec|
  spec.name = "fasthtmlparser"
  spec.version = FastHtmlParser::VERSION
  spec.authors = ["z3l"]
  spec.summary = "Fast HTML / XML parser for scraping, with XPath 1.0 and CSS selectors. Ruby port of z3l.FastHtmlParser."
  spec.description = "A page becomes a flat list of tags that hold only positions in the source; text, attributes " \
                     "and entities are read when they are asked for. HTML5 optional end tags, all 2125 named " \
                     "entities, XPath 1.0, CSS selectors, links resolved against the page URL. Pure Ruby, no " \
                     "dependencies."
  spec.homepage = "https://github.com/romanti3172/fasthtmlparser-rb"
  spec.license = "LicenseRef-z3l-source-available"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb"] + %w[LICENSE.md README.md fasthtmlparser.gemspec]
  spec.require_paths = ["lib"]
end
