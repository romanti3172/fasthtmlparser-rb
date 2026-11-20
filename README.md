# fasthtmlparser for Ruby

[![CI](https://github.com/romanti3172/fasthtmlparser-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/romanti3172/fasthtmlparser-rb/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/fasthtmlparser)](https://rubygems.org/gems/fasthtmlparser)

**Website:** [fasthtmlparser.com](https://fasthtmlparser.com): try the parser on any page, documentation and every language.

Ruby port of [z3l.FastHtmlParser](https://github.com/romanti3172/z3l.FastHtmlParser): a fast HTML / XML parser for
scraping, with **XPath 1.0** and **CSS selectors**. It is built for extracting data, not for building a DOM: a page
becomes a flat list of tags that hold only positions in the source. Text, attributes and entities are read when you
ask for them, and the values are substrings of the page.

The whole API is ported: the parser, attributes, HTML5 entities, visible text and text with line breaks,
`find` / `find_all` and `Query`, navigation, links, XPath 1.0, CSS selectors and the one-call shortcuts. There are also
ports for [Go](https://github.com/romanti3172/fasthtmlparser),
[JavaScript](https://github.com/romanti3172/fasthtmlparser-js), [Rust](https://github.com/romanti3172/fasthtmlparser-rs),
[Python](https://github.com/romanti3172/fasthtmlparser-py), [Java](https://github.com/romanti3172/fasthtmlparser-java)
and [PHP](https://github.com/romanti3172/fasthtmlparser-php).

```
gem install fasthtmlparser
```

Pure Ruby, no dependencies. Ruby 3.2 or later.

```ruby
require "fasthtmlparser"
include FastHtmlParser # Query, Tag, Attr, Html, CssQuery, XPathQuery

doc = FastHtmlParser.parse(page, "https://example.com/catalog/") # UTF-8; a byte order mark is skipped

# CSS selectors, as querySelectorAll / querySelector / matches
doc.css("article.product_pod").each do |pod|
  title = pod.css_first("h3 a").attr("title")
  price = pod.css_first("p.price_color").text
end
doc.css_first("ul#menu > li:last-child a").attr("href")
doc.css("tr:has(> td.price)")
card.css("> span") # the children of card

# XPath 1.0
doc.xpath("//div[@class='card']//span[@class='price']")
doc.xpath_values("//a[contains(@href, '/product/')]/@href")
doc.xpath_value("//dt[.='Price']/following-sibling::dd[1]")
doc.xpath_value("count(//table//tr)") # "12"

# compile once, reuse on any number of pages (and threads)
TITLES = XPathQuery.compile("//article//h3/a/@title")
TITLES.values(doc)

# search by name, class, id, attribute, text
doc.find_all(Query.by(:article).has_class("product_pod")).each do |pod|
  pod.find(Query.by(:p).has_class("price_color")).text
end

# one-call shortcuts (find_by_name_*, find_all_by_name_*, is_name_*?, parent_by_name, next_sibling_by_name,
# attribute_*, ...)
pod = doc.find_by_name_class(:article, "product_pod")
pod.find_by_name_itemprop(:span, "price").text
doc.find_by_name_text(:dt, "Price").next_sibling_by_name(:dd).text
doc.find_by_name_class("my-widget", "x") # any name works as a String or Symbol

# reading a tag
tag.text             # visible text, entities decoded
tag.text_line_breaks # <br> and block elements -> new line, <p> and headings -> paragraph
tag.attr(Attr::DATA_SRC) # decoded value; attr_raw: as written; has_attr?, has_class?, attrs
tag.href             # absolute URL, resolved against the page URL; src for src
tag.href_mail_to     # the address of a mailto: link; href_telephone for tel:
tag.source           # the opening tag without '<' and '>'
tag.name; tag.tag; tag.depth; tag.index; tag.start; tag.end

# navigation
tag.parent; tag.children; tag.next_sibling; tag.previous_sibling; tag.next; tag.previous
tag.parent_matching(Query.by(:table))
tag.text_after_until(Query.by(:br)) # the source between the tag and the next <br>
```

Queries: `Query.by(:div)`, `Query.by("custom-tag")` or `Query.any`, then `.has_class`, `.id`, `.attr`, `.text`,
`.id_starts_with`, `.text_starts_with`, `.body`, `.body_starts_with`, `.source`. Queries are immutable (frozen).
Tag names are symbols (`Tag::DIV` is `:div`, `Tag::COMMENT` is `:"!--"`) and `Attr` holds string constants
(`Attr::CLASS`, `Attr::DATA_SRC`); the two modules cover about 250 tag and 230 attribute names (HTML, SVG, MathML,
RSS, Atom, sitemap), and any other name works as a String or Symbol. Every method that takes a tag name takes a Symbol
or a String, case-insensitively.

The names are those of the other ports in Ruby style: `findByNameClass` is `find_by_name_class`, the predicates end
with `?` (`has_attr?`, `has_class?`, `has_children?`, `is?(query)`, `is_css?(selector)`, `is_name_class?(...)`).

A missing tag is `nil`; a missing value is `""`. The string methods (`css`, `xpath`, ...) compile and cache the query
and raise `CssSelectorError` / `XPathError` (both `ArgumentError`s) on an invalid one; `xpath` on an expression that
gives a number or string raises an `XPathError` (use `xpath_value`). `Html.to_text`, `Html.to_text_line_breaks` and
`Html.decode` work on HTML fragments. A document is an `Enumerable` of its tags (`doc[i]`, `doc.size`, `doc.each`).

Documents are read-only, and documents and compiled queries can be shared between threads. The tags are kept as
arrays of positions; a tag object (`HtmlNode`) is made the first time a search, a selector or `node(i)` returns it.

CSS: type, `*`, `#id`, `.class`, attribute selectors with all operators and the `i` / `s` flags, the four combinators,
selector lists, `:first-child`, `:last-child`, `:only-child`, `:*-of-type`, `:nth-child(An+B [of S])` and its
relatives, `:not()`, `:is()`, `:where()`, `:has()`, `:empty`, `:root`, `:scope`, `:link`, `:checked`, `:disabled`,
`:enabled`, `:required`, `:optional`, `:contains("text")`. XPath: all axes except namespace, predicates, `|`, the
operators and all XPath 1.0 functions, plus `ends-with()`, `lower-case()`, `upper-case()`. HTML rules apply: names are
case-insensitive, the string-value of an element is its visible text, attribute values and text are decoded.

Parsing follows what a browser makes of the page where it matters for scraping: HTML5 optional end tags (`<li>`, `<p>`,
`<td>`, `<tr>`, `<option>` without end tags give the same elements as a browser), raw text in `<script>`, `<style>`,
`<textarea>`, `<title>`, comments as HTML5 reads them, void elements, nesting flattened past 512 levels, all 2125
named entities, CR LF read as LF. XML documents (RSS, Atom, sitemaps) are parsed by XML rules. Not done: full HTML5
tree construction (no implied `<tbody>` or `<html>`), and documents are read-only.

## Strings and positions

The page is read as UTF-8 bytes, whatever the encoding of the String you pass (the string itself is not changed), and
every string the library gives back is UTF-8. Positions (`start`, `end`) are **byte offsets** into the source, as in
the Go, Rust, Python and PHP ports: `doc.source.byteslice(tag.start, tag.end - tag.start + 1)` is the whole element.
(.NET, Java and JavaScript count UTF-16 units; the conformance data holds byte offsets, so every port is checked
against the same numbers.) XPath counts as .NET does: `string-length()` gives UTF-16 units (an emoji is 2),
`substring()` and `translate()` work on characters. Broken UTF-8 does not raise: the bytes are kept as they are.

Intended differences from .NET: `text_line_breaks` joins lines with `"\n"` on every OS (.NET uses
`Environment.NewLine`), and a missing value is `""` where .NET returns null. Links resolved against the page are
written as .NET's `System.Uri` writes them (host in lower case, no default port, readable escapes); absolute links are
returned as written.

## Same results as the .NET version

The conformance tests compare the port with z3l.FastHtmlParser 1.4.1 (.NET) on 117 pages: the test fixtures, the
broken-markup snippets of the .NET cross-check tests, extra edge cases (entities, raw text, comments, XML, custom
elements, 600-deep nesting, Unicode whitespace, links of every kind, line breaks), and every fixture with
`</li> </p> </td> </tr>` left out, plus three copies of each with random end tags dropped, names upper-cased and the
page cut off, and copies saved with CR LF and with a lone CR.

- `test_tags_texts_attributes_navigation_and_links_*`, every tag (over 15,000): names, parents, depths, positions,
  visible text, text with line breaks, 10 attribute values, the opening tag source, next / previous tag and sibling,
  children, the resolved href and src, mailto: and tel: values, and the text after the tag must be identical.
- `test_xpath_and_css_results_*`, 569 queries: every string of the .NET XPath and CSS tests plus extra ones for the
  axes, functions and selectors. Whether each one compiles must be the same (119 are invalid); the 228 XPath and 222
  CSS queries that compile are run on every page, on the document and from three tags of the page, and every CSS
  selector is also matched against every tag. Selected tags and values must be identical.

All pass on Ruby 3.2 and 4.0, with one documented exception: on the page nested 600 levels deep, where the .NET result
depends on the order of an unstable sort.

The expected output in `testdata/conformance` is produced by `tools/conformance`, a small .NET program that references
the z3l.FastHtmlParser package; it is shared with the other ports.

## Benchmarks

`cd bench && bundle install && bundle exec ruby bench.rb` (Ruby 4.0.9, AMD Ryzen 7 3800X, Windows; median time per call
after a one-second warm-up). The RubyInstaller builds for Windows have no YJIT, so these numbers are for the plain
interpreter; with YJIT (Linux, macOS) the pure-Ruby parser gains more than the C parsers it is compared with. Nokogiri
1.19.7 parses with libxml2 2.13 (`Nokogiri::HTML4`) or with gumbo, the HTML5 parser (`Nokogiri::HTML5`); Oga 3.5 is a
pure-Ruby parser. Before timing, the benchmark checks that every library extracts exactly the same records.

Parse a page:

| Page | fasthtmlparser | Nokogiri HTML4 | Nokogiri HTML5 | Oga |
|---|---:|---:|---:|---:|
| quotes, 11 KB | **456 μs** | 526 μs | 802 μs | 3.14 ms |
| laptops, 38 KB | **1.40 ms** | 1.79 ms | 2.38 ms | 10.11 ms |
| books, 51 KB | 1.54 ms | **1.45 ms** | 3.23 ms | 10.28 ms |
| books x10, 510 KB | 15.47 ms | **14.44 ms** | 31.01 ms | 107.99 ms |
| books without `</li>` `</p>` | 1.97 ms | **1.56 ms** | 2.83 ms | 9.62 ms |

Scrape a page: parse and extract the records. Books: 20 × title, price, rating; quotes: 10 × text, author, tags.

| Task | fasthtmlparser `find` | CSS | XPath | Nokogiri HTML4 CSS | HTML4 XPath | HTML5 CSS | HTML5 XPath | Oga CSS | Oga XPath |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| books | **2.26 ms** | 2.48 ms | 3.05 ms | 3.13 ms | 2.74 ms | 4.57 ms | 3.88 ms | 13.86 ms | 14.28 ms |
| quotes | **834 μs** | 881 μs | 1.21 ms | 1.32 ms |  | 1.55 ms |  | 4.66 ms |  |

A pure-Ruby parser that keeps only positions parses about as fast as libxml2 and 2x faster than gumbo; extracting the
records is where it wins, because nothing is built that is not asked for. The full output is in `bench-results.md`.

## Development

```
bundle install
bundle exec rake test                                   # API and conformance tests
ruby tools/gen.rb ../z3l.FastHtmlParser/src/z3l.FastHtmlParser   # tag, attribute and entity tables, shortcuts
cd bench && bundle install && bundle exec ruby bench.rb # benchmarks (they load the library from ..)
```

Releases: bump `VERSION` in `lib/fasthtmlparser/version.rb`, commit, push a tag `v<version>`; `.github/workflows/publish.yml`
publishes the gem through rubygems.org trusted publishing (no API key stored).

- `lib/fasthtmlparser/parser.rb`: the scanner and the HTML5 optional-end-tag rules (port of `ParsingCore.cs`); it
  writes the tags into parallel arrays of the document
- `lib/fasthtmlparser/attrs.rb`, `decode.rb`, `text.rb`: attributes, character references, visible text and text with
  line breaks
- `lib/fasthtmlparser/html_document.rb`, `html_node.rb`, `query.rb`: search, navigation and the generated shortcuts;
  `links.rb`: href / src
- `lib/fasthtmlparser/css.rb`: CSS selectors; `xpath.rb`, `xpath_compiler.rb`: XPath 1.0
- `lib/fasthtmlparser/tags.rb`, `attr.rb`, `entities.rb`: generated by `tools/gen.rb` from the C# sources
- `bench/`: benchmarks with their own Gemfile, so the library has no dependencies

## License

Source-available, not OSI open source: free for individuals and companies with annual revenue below USD 1,000,000
and fewer than 100 people; a one-time commercial license above that. See [LICENSE.md](LICENSE.md).
