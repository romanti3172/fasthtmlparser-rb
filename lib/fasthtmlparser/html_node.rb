# frozen_string_literal: true

module FastHtmlParser
  # One tag of a document. Positions are byte offsets into the document source (String#byteslice works with them).
  # Methods that look for another tag return nil when there is none; methods that read a value return "" when there
  # is none. Strings are UTF-8.
  class HtmlNode
    TAG_SYMBOLS = TagNames::NAMES.map(&:to_sym).freeze

    # The document the tag belongs to.
    attr_reader :doc
    # The position of the tag in the document.
    attr_reader :index
    # The byte offset of the opening '<' in the source.
    attr_reader :start
    # The byte offset of the last '>': of the end tag when there is one, otherwise of the opening tag.
    attr_reader :end
    # The nesting depth: 0 for top-level tags.
    attr_reader :depth
    # The index of the enclosing tag, -1 at the top level.
    attr_reader :parent_index
    # The byte offset right after the opening tag; 0 when the tag is not closed.
    attr_reader :inner_start
    # The byte offset of the last byte before the end tag; 0 when the tag is not closed.
    attr_reader :inner_end
    # @api private Tag key, or -1 for a name that is not in Tag
    attr_reader :key
    # @api private the lower-case name (binary) of a tag that is not in Tag, "" for the others
    attr_reader :custom

    alias document doc

    # @api private Tags are made by the document: HtmlDocument#node.
    def initialize(doc, i)
      @doc = doc
      @index = i
      @parent_index = doc.parents[i]
      @key = doc.keys[i]
      @custom = doc.customs[i]
      @start = doc.starts[i]
      @end = doc.ends[i]
      @inner_start = doc.inner_starts[i]
      @inner_end = doc.inner_ends[i]
      @depth = doc.depths[i]
    end

    def ==(other)
      other.is_a?(HtmlNode) && other.doc.equal?(@doc) && other.index == @index
    end
    alias eql? ==

    def hash
      [@doc.object_id, @index].hash
    end

    # ----- reading a tag -----

    # The tag as a Symbol (:div, :"!--" for comments), or nil for a name that is not one of the known tags.
    def tag
      @key >= 0 ? TAG_SYMBOLS[@key] : nil
    end

    # The lower-case tag name ("div", "!--" for comments, "custom-tag", ...).
    def name
      @key >= 0 ? TagNames::NAMES[@key] : Chars.u(@custom)
    end

    # @api private name as binary bytes
    def name_bytes
      @key >= 0 ? TagNames::NAMES[@key] : @custom
    end

    # The inner HTML (trimmed); "" for tags that are not closed.
    def body
      Chars.u(body_bytes)
    end

    # @api private
    def body_bytes
      return +"".b if @inner_start.negative? || @inner_end <= 0

      Chars.trim_range(@doc.source_bytes, @inner_start, @inner_end + 1)
    end

    # The source of the whole element; "" for tags that are not closed.
    def outer_html
      return +"" if @inner_start <= 0 || @inner_end <= 0

      Chars.u(Chars.trim_range(@doc.source_bytes, @start, @end + 1))
    end

    # The visible text with entities decoded. With child tags: tags, comments and the content of script, style,
    # noscript, template, noframes, noembed removed, whitespace collapsed; without: the inner text as is (trimmed).
    def text
      Chars.u(text_bytes)
    end

    # @api private
    def text_bytes
      body = body_bytes
      # No child tags and no '<' at all: the body is the text, except in script, style, textarea, title, ...
      if !has_children? && (!body.include?(Text::LT) || Parser.raw_text?(@key))
        return Decode.needs_decoding?(body) ? Decode.decode(body, false) : body
      end

      Text.clear_tags(body)
    end

    # The text with the visible line structure kept: <br> and block elements give new lines, p and headings a blank
    # line, td / th a space; lines are trimmed and joined with "\n".
    def text_line_breaks
      return +"" if @inner_start.negative? || @inner_end <= 0

      Chars.u(TextLines.clear_tags_line_breaks(body_bytes))
    end

    # Whether another tag starts inside this one.
    def has_children?
      i = @index + 1
      i < @doc.size && @doc.starts[i] < @end
    end

    # The opening tag without '<' and '>': the name and the attributes.
    def source
      Chars.u(source_bytes)
    end

    # @api private
    def source_bytes
      src = @doc.source_bytes
      length = if @inner_start.positive? && @inner_end.positive?
                 @inner_start - @start - 2
               elsif @end.positive? && @end - 1 < src.bytesize && src.getbyte(@end - 1) == 47
                 @end - @start - 2
               else
                 @end - @start - 1
               end
      Chars.trim_range(src, @start + 1, @start + 1 + length)
    end

    def to_s
      "<#{source}>"
    end

    def inspect
      "#<#{self.class.name} #{index} #{to_s[0, 80]}>"
    end

    # ----- attributes -----

    # The decoded value of the first attribute with the name (case-insensitive); "" when it is missing or has no
    # value.
    def attr(name)
      Chars.u(Attrs.attr_value(self, attr_name(name)))
    end

    # The value of the attribute as written in the source.
    def attr_raw(name)
      Chars.u(Attrs.attr_raw(self, attr_name(name)))
    end

    # Whether the tag has the attribute, with or without a value (case-insensitive name).
    def has_attr?(name)
      Attrs.has_attribute?(self, attr_name(name))
    end

    # Whether one of the space-separated classes equals cls (case-insensitive).
    def has_class?(cls)
      Attrs.has_class?(self, Chars.b(cls))
    end

    # Every attribute of the opening tag: [name as written, raw value] pairs in source order.
    def attrs
      out = []
      return out if @key == Parser::COMMENT

      s = AttrScanner.new(self)
      out << [Chars.u(s.name), Chars.u(s.raw_value)] while s.next?
      out
    end

    # The link a browser follows: href decoded and made absolute against the page URL; an empty or missing href gives
    # the page URL.
    def href
      Chars.u(Links.correct_link(Attrs.attr_raw(self, "href"), @doc.url_bytes, @doc.base))
    end

    # href resolved against base_url instead of the page URL.
    def href_from(base_url)
      base = Chars.b(base_url)
      Chars.u(Links.correct_link(Attrs.attr_raw(self, "href"), base, Links.absolute_url(base)))
    end

    # The src attribute decoded and made absolute against the page URL.
    def src
      Chars.u(Links.correct_link(Attrs.attr_raw(self, "src"), @doc.url_bytes, @doc.base))
    end

    # src resolved against base_url instead of the page URL.
    def src_from(base_url)
      base = Chars.b(base_url)
      Chars.u(Links.correct_link(Attrs.attr_raw(self, "src"), base, Links.absolute_url(base)))
    end

    # The address of a mailto: link (everything after the first ':'), or "".
    def href_mail_to
      Chars.u(Links.after_scheme(Attrs.attr_raw(self, "href"), "mailto"))
    end

    # The number of a tel: link (everything after the first ':'), or "".
    def href_telephone
      Chars.u(Links.after_scheme(Attrs.attr_raw(self, "href"), "tel"))
    end

    # ----- navigation -----

    # The enclosing tag, or nil.
    def parent
      @parent_index >= 0 ? @doc.at(@parent_index) : nil
    end

    # The direct children: the tags inside this one, one level deeper.
    def children
      out = []
      d = @doc
      ends = d.ends
      depths = d.depths
      depth = @depth + 1
      i = @index + 1
      count = d.size
      while i < count && ends[i] <= @end
        out << d.at(i) if depths[i] == depth
        i += 1
      end
      out
    end

    # The tag that follows in document order (the first child, if there is one), or nil.
    def next
      @doc.node(@index + 1)
    end

    # The tag before this one in document order, or nil.
    def previous
      @index.positive? ? @doc.at(@index - 1) : nil
    end

    # The first tag after the end of this one that matches the query (tags inside it are skipped), or nil.
    def next_matching(query)
      d = @doc
      starts = d.starts
      i = @index + 1
      count = d.size
      while i < count
        return d.at(i) if starts[i] > @end && query.name_matches_at?(d, i) && query.matches?(d.at(i))

        i += 1
      end
      nil
    end

    # The next tag at the same level inside the same parent, or nil.
    def next_sibling
      next_sibling_matching(Query.any)
    end

    # The next sibling that matches the query, or nil.
    def next_sibling_matching(query)
      # deeper tags are inside the following siblings; a shallower one ends the parent
      d = @doc
      depths = d.depths
      i = @index + 1
      count = d.size
      while i < count && depths[i] >= @depth
        return d.at(i) if depths[i] == @depth && query.name_matches_at?(d, i) && query.matches?(d.at(i))

        i += 1
      end
      nil
    end

    # The previous tag at the same level inside the same parent, or nil.
    def previous_sibling
      previous_sibling_matching(Query.any)
    end

    # The nearest previous sibling that matches the query, or nil.
    def previous_sibling_matching(query)
      # deeper tags are inside the previous siblings; a shallower one is the parent
      d = @doc
      depths = d.depths
      i = @index - 1
      while i >= 0 && depths[i] >= @depth
        return d.at(i) if depths[i] == @depth && query.name_matches_at?(d, i) && query.matches?(d.at(i))

        i -= 1
      end
      nil
    end

    # The nearest enclosing tag that matches the query, or nil.
    def parent_matching(query)
      p = parent
      until p.nil?
        return p if query.matches?(p)

        p = p.parent
      end
      nil
    end

    # The source text right after the tag up to the next '<' (or the end of the page).
    def text_after_tag_until_next_one
      Chars.u(text_after_bytes)
    end

    # text_after_tag_until_next_one as visible text: entities decoded, whitespace collapsed.
    def text_no_tags_after_tag_until_next_one
      Chars.u(Text.clear_tags(text_after_bytes))
    end

    # The source between the end of the tag and the next tag that matches the query; "" when there is none.
    def text_after_until(query)
      until_ = next_matching(query)
      until_.nil? ? +"" : Chars.u(Chars.slice(@doc.source_bytes, @end + 1, until_.start))
    end

    # ----- search -----

    # The first tag inside this one (a descendant) that matches the query, or nil.
    def find(query)
      query.find_in(@doc, @index + 1, @end)
    end

    # All tags inside this one (descendants) that match the query.
    def find_all(query)
      query.find_all_in(@doc, @index + 1, @end)
    end

    # Whether the tag matches the query.
    def is?(query)
      query.matches?(self)
    end

    # The tags inside this one that match a CSS selector (as querySelectorAll); :scope is this tag, "> li" its
    # children.
    def css(selector)
      CssQuery.cached(selector).all_in(self)
    end

    # The first tag inside this one that matches a CSS selector, or nil.
    def css_first(selector)
      CssQuery.cached(selector).first_in(self)
    end

    # Whether the tag matches a CSS selector (as element.matches()).
    def is_css?(selector)
      CssQuery.cached(selector).matches?(self)
    end

    # The tags an XPath expression selects; relative paths start at this tag, '/' and '//' search the whole document.
    def xpath(expression)
      XPathQuery.cached(expression).nodes_from(self)
    end

    # The first tag an XPath expression selects from this tag, or nil.
    def xpath_first(expression)
      xpath(expression).first
    end

    # The values an XPath expression selects from this tag.
    def xpath_values(expression)
      XPathQuery.cached(expression).values_from(self)
    end

    # The first value an XPath expression selects from this tag, or "".
    def xpath_value(expression)
      XPathQuery.cached(expression).value_from(self) || +""
    end

    private

    def text_after_bytes
      src = @doc.source_bytes
      from = @end + 1
      return +"".b if from >= src.bytesize

      nxt = src.index(Text::LT, from)
      nxt.nil? ? src.byteslice(from, src.bytesize - from) : src.byteslice(from, nxt - from)
    end

    def attr_name(name)
      Chars.b(name).downcase(:ascii)
    end

    public

    # <shortcuts node>
    # Generated by tools/gen.rb; do not edit by hand.

    # Returns the first tag with the id inside the tag, or nil.
    def find_by_id(id)
      return nil if id.empty?

      find(Query.any.id(id))
    end

    # Returns the first tag with the name inside the tag, or nil.
    def find_by_name(name)
      find(Query.by(name))
    end

    # Returns the first tag with the name and the inner HTML inside the tag, or nil.
    def find_by_name_body(name, body)
      find(Query.by(name).body(body))
    end

    # Returns the first tag with the name and the decoded attribute value inside the tag, or nil.
    def find_by_name_attribute(name, attribute, value)
      find(Query.by(name).attr(attribute, value))
    end

    # Returns the first tag with the name and the class inside the tag, or nil.
    def find_by_name_class(name, cls)
      find(Query.by(name).has_class(cls))
    end

    # Returns the first tag with the name, the class and the inner HTML inside the tag, or nil.
    def find_by_name_class_body(name, cls, body)
      find(Query.by(name).has_class(cls).body(body))
    end

    # Returns the first tag with the name, and the class and visible text when they are not empty inside the tag, or nil.
    def find_by_name_class_text(name, cls, text)
      find(Query.opt_text(Query.opt_class(Query.by(name), cls), text))
    end

    # Returns the first tag with the name, and the id and visible text when they are not empty inside the tag, or nil.
    def find_by_name_id_text(name, id, text)
      find(Query.opt_text(Query.opt_id(Query.by(name), id), text))
    end

    # Returns the first tag with the name and the visible text inside the tag, or nil.
    def find_by_name_text(name, text)
      find(Query.by(name).text(text))
    end

    # Returns the first tag with the name and the id inside the tag, or nil.
    def find_by_name_id(name, id)
      find(Query.by(name).id(id))
    end

    # Returns the first tag with the name whose id starts with the prefix inside the tag, or nil.
    def find_by_name_id_starts_with(name, id_prefix)
      find(Query.by(name).id_starts_with(id_prefix))
    end

    # Returns the first tag with the name whose inner HTML starts with the prefix inside the tag, or nil.
    def find_by_name_body_starts_with(name, body_prefix)
      find(Query.by(name).body_starts_with(body_prefix))
    end

    # Returns the first tag with the name whose visible text starts with the prefix inside the tag, or nil.
    def find_by_name_text_starts_with(name, text_prefix)
      return nil if text_prefix.empty?

      find(Query.by(name).text_starts_with(text_prefix))
    end

    # Returns the first tag with the name and the class whose visible text starts with the prefix inside the tag, or nil.
    def find_by_name_class_text_starts_with(name, cls, text_prefix)
      return nil if text_prefix.empty?

      find(Query.by(name).has_class(cls).text_starts_with(text_prefix))
    end

    # Returns the first tag with the name and the itemprop inside the tag, or nil.
    def find_by_name_itemprop(name, itemprop)
      find(Query.by(name).attr(Attr::ITEMPROP, itemprop))
    end

    # Returns all tags with the name inside the tag.
    def find_all_by_name(name)
      find_all(Query.by(name))
    end

    # Returns all tags with the name and the decoded attribute value inside the tag.
    def find_all_by_name_attribute(name, attribute, value)
      find_all(Query.by(name).attr(attribute, value))
    end

    # Returns all tags with the name and the class inside the tag.
    def find_all_by_name_class(name, cls)
      find_all(Query.by(name).has_class(cls))
    end

    # Returns all tags with the name and the id inside the tag.
    def find_all_by_name_id(name, id)
      find_all(Query.by(name).id(id))
    end

    # Returns all tags with the name whose id starts with the prefix inside the tag.
    def find_all_by_name_id_starts_with(name, id_prefix)
      find_all(Query.by(name).id_starts_with(id_prefix))
    end

    # Returns all tags with the name and the itemprop inside the tag.
    def find_all_by_name_itemprop(name, itemprop)
      find_all(Query.by(name).attr(Attr::ITEMPROP, itemprop))
    end

    # Returns all tags with the name whose inner HTML starts with the prefix inside the tag.
    def find_all_by_name_body_starts_with(name, body_prefix)
      find_all(Query.by(name).body_starts_with(body_prefix))
    end

    # Whether the tag has the name and the decoded attribute value.
    def is_name_attribute?(name, attribute, value)
      is?(Query.by(name).attr(attribute, value))
    end

    # Whether the tag has the name and the inner HTML.
    def is_name_body?(name, body)
      is?(Query.by(name).body(body))
    end

    # Whether the tag has the name and the visible text.
    def is_name_text?(name, text)
      is?(Query.by(name).text(text))
    end

    # Whether the tag has the name and the class.
    def is_name_class?(name, cls)
      is?(Query.by(name).has_class(cls))
    end

    # Whether the tag has the name, the class and the inner HTML.
    def is_name_class_body?(name, cls, body)
      is?(Query.by(name).has_class(cls).body(body))
    end

    # Whether the tag has the name, and the class, id and inner HTML when they are not empty.
    def is_name_class_id_body?(name, cls, id, body)
      is?(Query.opt_body(Query.opt_id(Query.opt_class(Query.by(name), cls), id), body))
    end

    # Whether the tag has the name, and the class and visible text when they are not empty.
    def is_name_class_text?(name, cls, text)
      is?(Query.opt_text(Query.opt_class(Query.by(name), cls), text))
    end

    # Whether the tag has the name, and the id and visible text when they are not empty.
    def is_name_id_text?(name, id, text)
      is?(Query.opt_text(Query.opt_id(Query.by(name), id), text))
    end

    # Whether the tag has the name and the id.
    def is_name_id?(name, id)
      is?(Query.by(name).id(id))
    end

    # Whether the tag has the name and its visible text starts with the prefix.
    def is_name_text_starts_with?(name, text_prefix)
      is?(Query.by(name).text_starts_with(text_prefix))
    end

    # Whether the tag has the name and its inner HTML starts with the prefix.
    def is_name_body_starts_with?(name, body_prefix)
      is?(Query.by(name).body_starts_with(body_prefix))
    end

    # Whether the tag has the name and the class and its visible text starts with the prefix.
    def is_name_class_text_starts_with?(name, cls, text_prefix)
      is?(Query.by(name).has_class(cls).text_starts_with(text_prefix))
    end

    # Whether the tag has the name and its id starts with the prefix.
    def is_name_id_starts_with?(name, id_prefix)
      is?(Query.by(name).id_starts_with(id_prefix))
    end

    # Whether the tag has the name and the itemprop.
    def is_name_itemprop?(name, itemprop)
      is?(Query.by(name).attr(Attr::ITEMPROP, itemprop))
    end

    # Whether the tag has the name and its opening tag (without '<' and '>') equals source.
    def is_name_source?(name, source)
      is?(Query.by(name).source(source))
    end

    # Returns the nearest enclosing tag with the name, or nil.
    def parent_by_name(name)
      parent_matching(Query.by(name))
    end

    # Returns the nearest enclosing tag with the name and the class, or nil.
    def parent_by_name_class(name, cls)
      parent_matching(Query.by(name).has_class(cls))
    end

    # Returns the first tag with the name after the end of this one, or nil.
    def next_by_name(name)
      next_matching(Query.by(name))
    end

    # Returns the first tag with the name and the class after the end of this one, or nil.
    def next_by_name_class(name, cls)
      next_matching(Query.by(name).has_class(cls))
    end

    # Returns the next sibling with the name, or nil.
    def next_sibling_by_name(name)
      next_sibling_matching(Query.by(name))
    end

    # Returns the next sibling with the name and the class, or nil.
    def next_sibling_by_name_class(name, cls)
      next_sibling_matching(Query.by(name).has_class(cls))
    end

    # Returns the nearest previous sibling with the name, or nil.
    def previous_sibling_by_name(name)
      previous_sibling_matching(Query.by(name))
    end

    # Returns the source between the end of this tag and the next tag with the name.
    def text_after_until_tag_by_name(name)
      text_after_until(Query.by(name))
    end

    # Returns the source between the end of this tag and the next tag with the name and the class.
    def text_after_until_tag_by_name_class(name, cls)
      text_after_until(Query.by(name).has_class(cls))
    end

    # The decoded value of the alt attribute; "" when it is missing.
    def attribute_alt
      attr(Attr::ALT)
    end

    # The decoded value of the class attribute; "" when it is missing.
    def attribute_class
      attr(Attr::CLASS)
    end

    # The decoded value of the content attribute; "" when it is missing.
    def attribute_content
      attr(Attr::CONTENT)
    end

    # The decoded value of the id attribute; "" when it is missing.
    def attribute_id
      attr(Attr::ID)
    end

    # The decoded value of the itemprop attribute; "" when it is missing.
    def attribute_item_prop
      attr(Attr::ITEMPROP)
    end

    # The decoded value of the name attribute; "" when it is missing.
    def attribute_name
      attr(Attr::NAME)
    end

    # The decoded value of the style attribute; "" when it is missing.
    def attribute_style
      attr(Attr::STYLE)
    end

    # The decoded value of the title attribute; "" when it is missing.
    def attribute_title
      attr(Attr::TITLE)
    end

    # The decoded value of the value attribute; "" when it is missing.
    def attribute_value
      attr(Attr::VALUE)
    end
    # </shortcuts node>
  end
end
