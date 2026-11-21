# frozen_string_literal: true

require_relative "test_helper"

class ApiTest < Minitest::Test
  include FastHtmlParser

  def fixture(path)
    File.binread(File.expand_path("../testdata/#{path}", __dir__))
  end

  # The shortcuts on the books page give what the scraper code of the .NET examples expects.
  def test_shortcuts
    doc = HtmlDocument.parse(fixture("books/index.html"), "https://books.toscrape.com/index.html")
    pods = doc.find_all_by_name_class(Tag::ARTICLE, "product_pod")
    assert_equal 20, pods.size
    first = pods[0]
    assert_equal "A Light in the Attic", first.find_by_name(:h3).find_by_name(:a).attribute_title
    assert_equal "£51.77", first.find_by_name_class(:p, "price_color").text
    assert_equal "price_color", first.find_by_name_class_text_starts_with(:p, "price_color", "£5").attribute_class
    assert_equal "https://books.toscrape.com/catalogue/a-light-in-the-attic_1000/index.html",
                 first.find_by_name(:a).href
    assert_equal "https://books.toscrape.com/media/cache/2c/da/2cdad67c44b002e7ead0cc35693c0e8b.jpg",
                 first.find_by_name(:img).src
    assert_equal "product_pod", first.find_by_name(:img).parent_by_name(:article).attribute_class
    assert_equal "product_price", first.find_by_name(:h3).next_sibling_by_name(:div).attribute_class
    # names as strings work too
    assert_equal "£51.77", first.find_by_name_class("p", "price_color").text
    assert_equal "£51.77", first.find_by_name_class("P", "price_color").text

    assert_equal 1, Html.first_level_by_name(doc.find_all(Query.any), :html).size
    assert first.is_name_class?(:article, "product_pod")
    refute first.is_name_class?(:div, "product_pod")
    assert_nil doc.find_by_name_text_starts_with(:a, ""), "an empty criterion of the older shortcuts gives nil"
    assert_nil doc.find_by_id("")
  end

  def test_scraping_with_find_css_and_xpath_gives_the_same_records
    doc = HtmlDocument.parse(fixture("books/index.html"))
    by_find = doc.find_all(Query.by(:article).has_class("product_pod")).map do |pod|
      [
        pod.find(Query.by(:h3)).find(Query.by(:a)).attr(Attr::TITLE),
        pod.find(Query.by(:p).has_class("price_color")).text,
        pod.find(Query.by(:p).has_class("star-rating")).attr(Attr::CLASS)
      ]
    end
    by_css = doc.css("article.product_pod").map do |pod|
      [pod.css_first("h3 a").attr("title"), pod.css_first("p.price_color").text, pod.css_first("p.star-rating").attr("class")]
    end
    by_xpath = doc.xpath("//article[@class='product_pod']").map do |pod|
      [
        pod.xpath_value(".//h3/a/@title"),
        pod.xpath_value(".//p[@class='price_color']"),
        pod.xpath_value(".//p[contains(@class,'star-rating')]/@class")
      ]
    end
    assert_equal 20, by_find.size
    assert_equal by_find, by_css
    assert_equal by_find, by_xpath
  end

  # CR LF and a lone CR are LF in values, as a browser reads the page; a CR written as a character reference stays.
  def test_line_breaks_are_read_as_in_a_browser
    doc = HtmlDocument.parse("<meta name=\"d\" content=\"one\r\ntwo\rthree&#13;four\">" \
                             "<textarea>a\r\nb</textarea><pre>c\r\nd</pre><div class=\"x\r\ny\">t</div>")
    div = doc.find(Query.by(:div))
    assert_equal "one\ntwo\nthree\rfour", doc.find(Query.by(:meta)).attr("content")
    assert_equal "a\nb", doc.find(Query.by(:textarea)).text
    assert_equal "c\nd", doc.find(Query.by(:pre)).text
    assert_equal "a\nb", doc.xpath_value("//textarea/text()")
    assert_equal "one\ntwo\nthree\rfour", doc.xpath_value("//meta/@content")
    assert_equal "x\r\ny", div.attr_raw("class")
    assert div.has_class?("y")
    assert div.is?(Query.any.attr("class", "x\ny"))
    assert_equal 1, doc.css('div[class="x\\a y"]').size
  end

  def test_optional_end_tags_as_in_a_browser
    doc = HtmlDocument.parse("<ul><li>one<li>two<ul><li>a<li>b</ul><li>three</ul>" \
                             "<table><tr><td>1<td>2<tr><td>3</table><p>x<div>y</div>")
    assert_equal %w[li1 li1 li3 li3 li1], doc.css("ul > li").map { |n| "#{n.name}#{n.depth}" }
    assert_equal ["one", "two\na\nb", "three"], doc.css_first("ul").css("> li").map(&:text_line_breaks)
    assert_equal [2, 1], doc.css("tr").map { |n| n.children.size }
    assert_nil doc.css_first("div").parent, "<div> ends an open <p>"
  end

  def test_text_entities_raw_text_and_comments
    doc = HtmlDocument.parse("<div> a &amp;&nbsp;b <script>var x = \"<b>\";</script><!-- c --> <i>d</i>&copy2024 </div>" \
                             "<title>a &lt; b</title>")
    assert_equal "a & b d©2024", doc.css_first("div").text, "&nbsp; is a no-break space"
    assert_equal "a < b", doc.css_first("title").text
    assert_equal " c ", doc.xpath_value("//comment()")
    assert_equal "onetwo three", Html.to_text("<p>one</p><p>two&nbsp;three</p>")
    assert_equal "one\n\ntwo\nthree\n\nx y", Html.to_text_line_breaks("<p>one</p><p>two<br>three</p><td>x</td><td>y</td>")
    assert_equal "<AB&bogus;", Html.decode("&lt;&#x41;&#66;&bogus;")
  end

  def test_attributes
    doc = HtmlDocument.parse("<a href=/p?a=1&copy=2 title=\"see id=5\" data-x='<b>' id=main CLASS=\"One two\" hidden>x</a>")
    a = doc.css_first("a")
    assert_equal "/p?a=1&copy=2", a.attr("href")
    assert_equal "main", a.attr("id")
    assert_equal "main", a.attr(:ID)
    assert_equal "<b>", a.attr("data-x")
    assert_equal "", a.attr("hidden")
    assert_equal "", a.attr("missing")
    assert a.has_attr?("hidden")
    refute a.has_attr?("missing")
    assert a.has_class?("one") && a.has_class?("TWO") && !a.has_class?("on")
    assert HtmlDocument.parse("<b class=Main>x</b>").node(0).has_class?("main"), "a class of the same length, other case"
    assert_equal %w[href title data-x id CLASS hidden], a.attrs.map(&:first)
    assert a.is_css?("[hidden]") && a.is_css?("a#main.One")
    assert_equal "a href=/p?a=1&copy=2 title=\"see id=5\" data-x='<b>' id=main CLASS=\"One two\" hidden", a.source

    # a quote that is not closed in the tag: the value runs to the end of the tag
    b = HtmlDocument.parse('<b id=x title="one>two</b>').node(0)
    assert_equal "one", b.attr("title")
    assert_equal "x", b.attr("id")
  end

  def test_links
    doc = HtmlDocument.parse(
      '<a href="../x/y.html?q=1#f">1</a><a href="//cdn.example.com/a b">2</a><a href="">3</a>' \
      '<a href="mailto:me@example.com?subject=hi">4</a><a href="tel:+1 555">5</a><a href="https://Other.org/%7Ea">6</a>',
      "https://Example.com:443/catalog/page/index.html?sort=asc#top"
    )
    a = doc.css("a")
    assert_equal "https://example.com/catalog/x/y.html?q=1#f", a[0].href
    assert_equal "https://cdn.example.com/a b", a[1].href
    assert_equal "https://Example.com:443/catalog/page/index.html?sort=asc#top", a[2].href
    assert_equal "me@example.com?subject=hi", a[3].href_mail_to
    assert_equal "+1 555", a[4].href_telephone
    assert_equal "https://Other.org/%7Ea", a[5].href, "absolute links are returned as written"
    assert_equal "http://h.test/a/x/y.html?q=1#f", a[0].href_from("http://h.test/a/b/")
  end

  def test_xpath_values
    doc = HtmlDocument.parse("<dl><dt>Price</dt><dd>12.50</dd><dt>Stock</dt><dd>3</dd></dl><a href='/x'>a</a><a>b</a>")
    assert_equal "12.50", doc.xpath_value("//dt[.='Price']/following-sibling::dd[1]")
    assert_equal "2", doc.xpath_value("count(//a)")
    assert_equal "15.5", doc.xpath_value("sum(//dd)")
    assert_equal ["/x"], doc.xpath_values("//a/@href")
    assert_equal "", doc.xpath_value("//missing")
    assert_nil doc.xpath_first("//missing")
    assert_equal "true", doc.xpath_value("boolean(//dl)")
    # an attribute read as a string is decoded
    assert_equal "1", HtmlDocument.parse('<a title="x &amp; y">a</a>').xpath_value("count(//a[contains(@title, 'x & y')])")
    assert_raises(XPathError) { doc.xpath("count(//a)") } # a number is not tags
  end

  # Positions are byte offsets into the UTF-8 source, as String#byteslice uses them; string-length() counts UTF-16
  # units and substring() chars, as the .NET version does.
  def test_positions_and_string_functions_on_unicode_text
    doc = HtmlDocument.parse("<p>Привет 😀</p><b>x</b>")
    p = doc.node(0)
    b = doc.node(1)
    assert_equal 0, p.start
    assert_equal "<p>Привет 😀</p>".bytesize, b.start
    assert_equal "<b>x</b>", doc.source.byteslice(b.start, b.end - b.start + 1)
    assert_equal "9", doc.xpath_value("string-length(//p)"), "6 Cyrillic letters, a space and a surrogate pair"
    assert_equal "рив", doc.xpath_value("substring(//p, 2, 3)")
    assert_equal "ПРИВЕТ 😀", doc.xpath_value("upper-case(//p)")
    assert_equal "Пёвет 😀", doc.xpath_value("translate(//p, 'ри', 'ё')")
    assert_equal 1, doc.css("p:contains('Привет')").size
    assert_equal p, doc.find(Query.by(:p).text("Привет 😀"))
  end

  def test_invalid_queries
    doc = HtmlDocument.parse("<p>x</p>")
    e = assert_raises(CssSelectorError) { doc.css("p >") }
    assert_includes e.message, '"p >"'
    assert_raises(CssSelectorError) { CssQuery.compile("::before") }
    e = assert_raises(XPathError) { doc.xpath("//p[") }
    assert_includes e.message, '"//p["'
    assert_includes e.message, "unexpected end of the expression"
    assert_raises(XPathError) { XPathQuery.compile("$var") }
    assert_raises(ArgumentError) { doc.xpath("//p[unknown()]") }
  end

  def test_compiled_queries_and_the_byte_order_mark
    doc = HtmlDocument.parse("﻿<p class=a>é</p><p class=b>x</p>", "https://h.test/")
    assert doc.source.start_with?("<p"), "the byte order mark is skipped"
    css = CssQuery.compile("p.b")
    xpath = XPathQuery.compile("//p[@class='a']")
    assert_equal "x", css.first(doc).text
    assert_equal "é", xpath.value(doc)
    assert_equal 2, doc.size
    assert_equal 2, doc.count
    assert_equal :p, doc.node(0).tag
    assert_equal Tag::P, doc[0].tag
    assert_equal "p", doc.node(0).name
    assert_nil doc.node(5)
    assert_equal doc.node(1), doc[-1]
    assert_equal 2, doc.each.count
    assert_equal 2, doc.to_a.size
  end

  def test_custom_tags_and_comments
    doc = HtmlDocument.parse("<my-widget data-id=1><svg:path d=x/></my-widget><!-- note -->")
    w = doc.find_by_name("my-widget")
    assert_nil w.tag
    assert_equal "my-widget", w.name
    assert_equal "1", w.attr("data-id")
    assert_equal 1, doc.css("my-widget").size
    assert_equal w, doc.find_by_name(:"my-widget")
    assert_equal Tag::COMMENT, doc.node(2).tag
    assert_equal "!--", doc.node(2).name
    assert_equal "", doc.node(2).attr("note"), "a comment has no attributes"
    assert_equal "<my-widget data-id=1>", w.to_s
  end

  # Strings come back as UTF-8, whatever the encoding of the page string; the page string is not changed.
  def test_encodings
    page = "<p title='é'>ü &amp; ö</p>".b
    doc = HtmlDocument.parse(page)
    p = doc.node(0)
    [p.text, p.attr("title"), p.body, p.source, p.text_line_breaks, doc.source, doc.xpath_value("//p/@title"),
     doc.xpath_values("//p")[0], Html.to_text(page)].each do |s|
      assert_equal Encoding::UTF_8, s.encoding
      assert s.valid_encoding?
    end
    assert_equal Encoding::BINARY, page.encoding
    assert_equal "ü & ö", p.text
    assert_equal "é", p.attr("title")
    assert p.is?(Query.by(:p).attr("title", "é"))
    assert_equal 1, doc.css("p[title='é']").size
    # broken UTF-8 does not raise
    broken = HtmlDocument.parse("<p class=\"\xff\">a\xfeb</p>")
    assert_equal "a\xfeb".b, broken.node(0).text.b
    assert_equal 1, broken.css("p").size
  end

  # Documents are independent: parsing one page in the middle of working with another changes nothing.
  def test_documents_are_independent
    page = fixture("books/index.html")
    titles = ->(d) { d.css("article.product_pod h3 a").map { |a| a.attr("title") } }
    first = HtmlDocument.parse(page)
    expected = titles.call(first)
    5.times do |i|
      HtmlDocument.parse("<ul><li>#{i}<li><table><tr><td>x</ul>")
      assert_equal expected, titles.call(HtmlDocument.parse(page))
    end
    assert_equal expected, titles.call(first)
  end

  def test_documents_and_queries_can_be_shared_between_threads
    doc = HtmlDocument.parse(fixture("books/index.html"))
    q = XPathQuery.compile("//article//h3/a/@title")
    expected = q.values(doc)
    results = Array.new(4) { Thread.new { Array.new(5) { q.values(doc) } } }.flat_map(&:value)
    results.each { |r| assert_equal expected, r }
  end
end
