# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "digest"

# The expected output comes from z3l.FastHtmlParser (.NET) for the same pages (tools/conformance): tag names, parents,
# depths, positions (as UTF-8 byte offsets), visible texts, attribute values, navigation and links, and the results
# of 569 XPath / CSS queries. The Ruby port must give exactly the same.
class ConformanceTest < Minitest::Test
  DIR = File.expand_path("../testdata/conformance", __dir__)
  PAGE_URL = "https://Example.com:443/catalog/page-1.html?sort=asc#top" # as in tools/conformance/Program.cs
  ATTRIBUTES = %w[class id href title value alt data-a x a src].freeze

  # page and query where the .NET result depends on the order of an unstable sort (see the Go port):
  # snip039 nests 600 divs; text nodes and flattened tags share document-order keys.
  KNOWN_DIFFERENCES = { "snip039 //div/node()" => true }.freeze

  INPUTS = Dir.glob(File.join(DIR, "input", "*.html")).map { |f| File.basename(f, ".html") }.sort.freeze

  def self.json(path)
    JSON.parse(File.read(File.join(DIR, path), encoding: "UTF-8"))
  end

  def self.input(name)
    File.binread(File.join(DIR, "input", "#{name}.html"))
  end

  def index_of(node)
    node.nil? ? -1 : node.index
  end

  def short_text(v)
    s = v.is_a?(String) ? v.inspect : JSON.generate(v)
    s.size > 200 ? "#{s[0, 200]}..." : s
  end

  def test_inputs_present
    assert_operator INPUTS.size, :>=, 100
  end

  INPUTS.each do |name|
    define_method("test_tags_texts_attributes_navigation_and_links_#{name}") do
      check_tags(name)
    end
    define_method("test_xpath_and_css_results_#{name}") do
      check_queries(name)
    end
  end

  def check_tags(name)
    expected = self.class.json("expected/#{name}.json")
    doc = FastHtmlParser::HtmlDocument.parse(self.class.input(name), PAGE_URL)
    problems = []
    problems << "tags: #{doc.size}, .NET: #{expected.size}" if doc.size != expected.size
    [doc.size, expected.size].min.times do |i|
      break if problems.size >= 10

      n = doc.node(i)
      e = expected[i]
      got = {
        "name" => n.name,
        "parent" => n.parent_index,
        "depth" => n.depth,
        "start" => n.start,
        "end" => n.end,
        "innerStart" => n.inner_start,
        "innerEnd" => n.inner_end,
        "text" => n.text,
        "textLineBreaks" => n.text_line_breaks,
        "source" => n.source,
        "next" => index_of(n.next),
        "previous" => index_of(n.previous),
        "nextSibling" => index_of(n.next_sibling),
        "previousSibling" => index_of(n.previous_sibling),
        "children" => n.children.map(&:index).join(","),
        "href" => n.href,
        "src" => n.src,
        "mailto" => n.href_mail_to,
        "tel" => n.href_telephone,
        "textAfter" => n.text_after_tag_until_next_one,
        "textNoTagsAfter" => n.text_no_tags_after_tag_until_next_one
      }
      got.each do |key, value|
        want = e[key]
        next if value == want && (!value.is_a?(String) || value.encoding == Encoding::UTF_8 || key == "children")

        problems << "[#{i}] <#{n.name}> #{key}:\n  ruby: #{short_text(value)}\n  .net: #{short_text(want)}"
      end
      attrs = e["attrs"]
      ATTRIBUTES.each do |a|
        want = attrs[a] || ""
        got_a = n.attr(a)
        problems << "[#{i}] <#{n.name}> @#{a}: #{short_text(got_a)}, .NET: #{short_text(want)}" if got_a != want
      end
    end
    assert_empty problems.first(10), problems.first(10).join("\n")
  end

  def test_which_queries_compile
    expected = self.class.json("expected/queries/compile.json")
    problems = []
    expected["xpath"].each do |x, want|
      problems << "XPath #{short_text(x)}: .NET #{want}" if ok_or_error { FastHtmlParser::XPathQuery.compile(x) } != want
    end
    expected["css"].each do |c, want|
      problems << "CSS #{short_text(c)}: .NET #{want}" if ok_or_error { FastHtmlParser::CssQuery.compile(c) } != want
    end
    assert_empty problems, problems.join("\n")
  end

  def ok_or_error
    yield
    "ok"
  rescue ArgumentError
    "error"
  end

  # [count, hash] of the values, or "throws" when the evaluation raises (.NET throws).
  def digest
    v = begin
      yield
    rescue ArgumentError
      return "throws"
    end
    return v if ENV["FASTHTML_FULL"]

    [v.size.to_s, Digest::SHA256.hexdigest(v.join("\x01"))[0, 16]]
  end

  def check_queries(name)
    expected = self.class.json("expected/queries/#{name}.json")
    doc = FastHtmlParser::HtmlDocument.parse(self.class.input(name))
    scopes = expected["scopes"]
    problems = []

    expected["xpath"].each do |x, want|
      next if KNOWN_DIFFERENCES["#{name} #{x}"]

      q = FastHtmlParser::XPathQuery.compile(x)
      check(problems, "XPath tags #{x}", want["tags"], digest { q.nodes(doc).map { |n| n.index.to_s } })
      check(problems, "XPath values #{x}", want["values"], digest { q.values(doc) })
      check(problems, "XPath value #{x}", want["value"], digest { [q.value(doc) || "<null>"] })
      scoped = scopes.map do |s|
        n = doc.node(s)
        digest { q.nodes_from(n).map { |t| t.index.to_s } + ["|"] + q.values_from(n) }
      end
      check(problems, "XPath scoped #{x}", want["scoped"], scoped)
    end

    expected["css"].each do |c, want|
      q = FastHtmlParser::CssQuery.compile(c)
      check(problems, "CSS all #{c}", want["all"], digest { q.all(doc).map { |n| n.index.to_s } })
      check(problems, "CSS first #{c}", want["first"], digest do
        f = q.first(doc)
        [f.nil? ? "<null>" : f.index.to_s]
      end)
      check(problems, "CSS matches #{c}", want["matches"], digest { doc.select { |n| q.matches?(n) }.map { |n| n.index.to_s } })
      scoped = scopes.map do |s|
        n = doc.node(s)
        digest { q.all_in(n).map { |t| t.index.to_s } }
      end
      check(problems, "CSS scoped #{c}", want["scoped"], scoped)
    end
    assert_empty problems, problems.join("\n")
  end

  def check(problems, what, want, got)
    return if problems.size >= 10 || got == want

    problems << "#{what}\n  ruby: #{short_text(got)}\n  .net: #{short_text(want)}"
  end

  def test_number_to_string
    x = FastHtmlParser::XPathQuery
    assert_equal "0.1", x.number_to_string(0.1)
    assert_equal "100000000000000000000", x.number_to_string(1e20)
    assert_equal "1000000000000000000000", x.number_to_string(1e21)
    assert_equal "0.0000001", x.number_to_string(1e-7)
    assert_equal "-123.456", x.number_to_string(-123.456)
    assert_equal "0.30000000000000004", x.number_to_string(0.1 + 0.2)
    assert_equal "12", x.number_to_string(12.0)
    assert_equal "NaN", x.number_to_string(Float::NAN)
  end
end
