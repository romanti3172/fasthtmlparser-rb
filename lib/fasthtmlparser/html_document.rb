# frozen_string_literal: true

module FastHtmlParser
  # A parsed HTML or XML page: a flat list of tags in document order. Each tag holds only positions in the source;
  # text, attributes and entities are read lazily, when they are asked for, and the values are substrings of the page.
  # Documents are read-only and can be shared between threads.
  #
  #   doc = FastHtmlParser::HtmlDocument.parse(html, "https://example.com/catalog/")
  #   doc.css("article.product_pod").each do |pod|
  #     title = pod.css_first("h3 a").attr("title")
  #     price = pod.find_by_name_class(:p, "price_color").text
  #   end
  #   doc.xpath_value("//dt[.='Price']/following-sibling::dd[1]")
  class HtmlDocument
    include Enumerable

    BOM = "\xEF\xBB\xBF".b.freeze

    # @api private The tags as parallel arrays, by index in document order: Tag key (-1 for a name that is not in
    # Tag), custom lower-case name ("" for the others), parent index (-1 at the top level), depth, the opening '<',
    # the last '>' (of the end tag when there is one), right after the opening tag and the last byte before the end
    # tag (both 0 when the tag is not closed).
    attr_reader :keys, :customs, :parents, :depths, :starts, :ends, :inner_starts, :inner_ends

    # The number of tags (comments included).
    attr_reader :size

    # Parses an HTML or XML page given as a String (UTF-8 bytes in any String encoding; a leading byte order mark is
    # skipped). With the page URL, relative links (HtmlNode#href, HtmlNode#src) are resolved against it.
    def self.parse(html, url = "")
      src = html.b
      src = src.byteslice(3, src.bytesize - 3) if src.start_with?(BOM)
      new(src.freeze, url)
    end

    # @api private Use HtmlDocument.parse.
    def initialize(source, url)
      @source = source
      @url = Chars.b(url.to_s).dup.freeze
      @keys, @customs, @parents, @depths, @starts, @ends, @inner_starts, @inner_ends = Parser.parse_tags(source)
      @size = @keys.size
      @made = Array.new(@size) # the tag objects made so far
      @css_tree = nil
      @base = nil
      @base_parsed = false
      @source_utf8 = nil
    end

    # @api private The page source as binary bytes.
    def source_bytes
      @source
    end

    # @api private The page URL as binary bytes.
    def url_bytes
      @url
    end

    # @api private Sibling links and positions, built by the first selector that needs them.
    def css_tree
      @css_tree ||= CssTree.new(self)
    end

    # @api private The page URL parsed once, for resolving relative links.
    def base
      unless @base_parsed
        @base = Links.absolute_url(@url)
        @base_parsed = true
      end
      @base
    end

    # The page source (UTF-8, frozen). Positions (HtmlNode#start, HtmlNode#end) are byte offsets into it:
    # source.byteslice(tag.start, tag.end - tag.start + 1).
    def source
      @source_utf8 ||= @source.dup.force_encoding(Encoding::UTF_8).freeze
    end

    # The page URL given to parse, or "".
    def url
      Chars.u(@url)
    end

    # Every tag (comments included) in document order.
    def nodes
      Array.new(@size) { |i| @made[i] ||= HtmlNode.new(self, i) }
    end

    alias length size

    # The number of tags; with an argument or a block, as Enumerable#count.
    def count(*args, &block)
      args.empty? && block.nil? ? @size : super
    end

    def empty?
      @size.zero?
    end

    # The tag at index i in document order (negative: from the end), or nil when there is none.
    def node(i)
      i += @size if i.negative?
      return nil if i.negative? || i >= @size

      @made[i] ||= HtmlNode.new(self, i)
    end

    alias [] node

    # @api private The tag at an index that exists.
    def at(i)
      @made[i] ||= HtmlNode.new(self, i)
    end

    def each
      return enum_for(:each) { @size } unless block_given?

      i = 0
      while i < @size
        yield(@made[i] ||= HtmlNode.new(self, i))
        i += 1
      end
      self
    end

    def inspect
      "#<#{self.class.name} #{@size} tags, #{@source.bytesize} bytes>"
    end

    # ----- search -----

    # The first tag in the document that matches the query, or nil.
    def find(query)
      query.find_in(self, 0, Float::INFINITY)
    end

    # All tags in the document that match the query.
    def find_all(query)
      query.find_all_in(self, 0, Float::INFINITY)
    end

    # The tags that match a CSS selector (as querySelectorAll). Raises CssSelectorError on an invalid selector.
    def css(selector)
      CssQuery.cached(selector).all(self)
    end

    # The first tag that matches a CSS selector, or nil.
    def css_first(selector)
      CssQuery.cached(selector).first(self)
    end

    # The tags an XPath expression selects. Raises XPathError on an invalid expression or one that gives a number,
    # string or boolean (use xpath_value).
    def xpath(expression)
      XPathQuery.cached(expression).nodes(self)
    end

    # The first tag an XPath expression selects, or nil.
    def xpath_first(expression)
      xpath(expression).first
    end

    # The values an XPath expression selects: decoded attributes, text(), visible text of tags, or the result of
    # count(), string(), ... as one value.
    def xpath_values(expression)
      XPathQuery.cached(expression).values(self)
    end

    # The first value an XPath expression selects, or "".
    def xpath_value(expression)
      XPathQuery.cached(expression).value(self) || +""
    end

    # <shortcuts document>
    # Generated by tools/gen.rb; do not edit by hand.

    # Returns the first tag with the id in the document, or nil.
    def find_by_id(id)
      return nil if id.empty?

      find(Query.any.id(id))
    end

    # Returns the first tag with the name in the document, or nil.
    def find_by_name(name)
      find(Query.by(name))
    end

    # Returns the first tag with the name and the inner HTML in the document, or nil.
    def find_by_name_body(name, body)
      find(Query.by(name).body(body))
    end

    # Returns the first tag with the name and the decoded attribute value in the document, or nil.
    def find_by_name_attribute(name, attribute, value)
      find(Query.by(name).attr(attribute, value))
    end

    # Returns the first tag with the name and the class in the document, or nil.
    def find_by_name_class(name, cls)
      find(Query.by(name).has_class(cls))
    end

    # Returns the first tag with the name, the class and the inner HTML in the document, or nil.
    def find_by_name_class_body(name, cls, body)
      find(Query.by(name).has_class(cls).body(body))
    end

    # Returns the first tag with the name, and the class and visible text when they are not empty in the document, or nil.
    def find_by_name_class_text(name, cls, text)
      find(Query.opt_text(Query.opt_class(Query.by(name), cls), text))
    end

    # Returns the first tag with the name, and the id and visible text when they are not empty in the document, or nil.
    def find_by_name_id_text(name, id, text)
      find(Query.opt_text(Query.opt_id(Query.by(name), id), text))
    end

    # Returns the first tag with the name and the visible text in the document, or nil.
    def find_by_name_text(name, text)
      find(Query.by(name).text(text))
    end

    # Returns the first tag with the name and the id in the document, or nil.
    def find_by_name_id(name, id)
      find(Query.by(name).id(id))
    end

    # Returns the first tag with the name whose id starts with the prefix in the document, or nil.
    def find_by_name_id_starts_with(name, id_prefix)
      find(Query.by(name).id_starts_with(id_prefix))
    end

    # Returns the first tag with the name whose inner HTML starts with the prefix in the document, or nil.
    def find_by_name_body_starts_with(name, body_prefix)
      find(Query.by(name).body_starts_with(body_prefix))
    end

    # Returns the first tag with the name whose visible text starts with the prefix in the document, or nil.
    def find_by_name_text_starts_with(name, text_prefix)
      return nil if text_prefix.empty?

      find(Query.by(name).text_starts_with(text_prefix))
    end

    # Returns the first tag with the name and the class whose visible text starts with the prefix in the document, or nil.
    def find_by_name_class_text_starts_with(name, cls, text_prefix)
      return nil if text_prefix.empty?

      find(Query.by(name).has_class(cls).text_starts_with(text_prefix))
    end

    # Returns the first tag with the name and the itemprop in the document, or nil.
    def find_by_name_itemprop(name, itemprop)
      find(Query.by(name).attr(Attr::ITEMPROP, itemprop))
    end

    # Returns all tags with the name in the document.
    def find_all_by_name(name)
      find_all(Query.by(name))
    end

    # Returns all tags with the name and the decoded attribute value in the document.
    def find_all_by_name_attribute(name, attribute, value)
      find_all(Query.by(name).attr(attribute, value))
    end

    # Returns all tags with the name and the class in the document.
    def find_all_by_name_class(name, cls)
      find_all(Query.by(name).has_class(cls))
    end

    # Returns all tags with the name and the id in the document.
    def find_all_by_name_id(name, id)
      find_all(Query.by(name).id(id))
    end

    # Returns all tags with the name whose id starts with the prefix in the document.
    def find_all_by_name_id_starts_with(name, id_prefix)
      find_all(Query.by(name).id_starts_with(id_prefix))
    end

    # Returns all tags with the name and the itemprop in the document.
    def find_all_by_name_itemprop(name, itemprop)
      find_all(Query.by(name).attr(Attr::ITEMPROP, itemprop))
    end

    # Returns all tags with the name whose inner HTML starts with the prefix in the document.
    def find_all_by_name_body_starts_with(name, body_prefix)
      find_all(Query.by(name).body_starts_with(body_prefix))
    end
    # </shortcuts document>
  end
end
