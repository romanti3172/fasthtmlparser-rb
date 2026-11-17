# frozen_string_literal: true

module FastHtmlParser
  # An invalid CSS selector.
  class CssSelectorError < ArgumentError; end

  # An invalid XPath expression, or one that gives a number, string or boolean where tags are asked for.
  class XPathError < ArgumentError; end

  # Helpers for HTML fragments and lists of tags.
  module Html
    module_function

    # The visible text of an HTML fragment, as HtmlNode#text gives it for a tag's content.
    def to_text(html)
      Chars.u(Text.clear_tags(html.to_s.b))
    end

    # The text of an HTML fragment with the visible line structure kept, as HtmlNode#text_line_breaks.
    def to_text_line_breaks(html)
      Chars.u(TextLines.clear_tags_line_breaks(html.to_s.b))
    end

    # Decodes the HTML character references in text (&amp;amp;, &amp;#169;, ...); CR LF and a lone CR become LF.
    def decode(text)
      Chars.u(Decode.decode(text.to_s.b, false))
    end

    # The tags of the list at the level of the first one (the outermost tags of a find_all result).
    def first_level(nodes)
      level(nodes, nil)
    end

    # The tags of the list with the name, at the level of the first tag of the list.
    def first_level_by_name(nodes, name)
      level(nodes, Query.by(name))
    end

    # The tags of the list with the name and the class, at the level of the first tag of the list.
    def first_level_by_name_class(nodes, name, cls)
      level(nodes, Query.by(name).has_class(cls))
    end

    def level(nodes, query)
      return [] if nodes.empty?

      depth = nodes[0].depth
      nodes.select { |n| n.depth == depth && (query.nil? || query.matches?(n)) }
    end
    private_class_method :level
  end
end
