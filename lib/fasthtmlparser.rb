# frozen_string_literal: true

# Ruby port of z3l.FastHtmlParser: a fast HTML / XML parser for scraping, with XPath 1.0 and CSS selectors. A page
# becomes a flat list of tags that hold only positions in the source; text, attributes and entities are read when they
# are asked for.
#
#   require "fasthtmlparser"
#
#   doc = FastHtmlParser.parse(html, "https://example.com/catalog/")
#   doc.css("article.product_pod").map { |pod| pod.css_first("h3 a").attr("title") }
module FastHtmlParser
  # Parses an HTML or XML page; see HtmlDocument.parse.
  def self.parse(html, url = "")
    HtmlDocument.parse(html, url)
  end
end

require "strscan"
require_relative "fasthtmlparser/version"
require_relative "fasthtmlparser/tags"
require_relative "fasthtmlparser/attr"
require_relative "fasthtmlparser/entities"
require_relative "fasthtmlparser/chars"
require_relative "fasthtmlparser/html"
require_relative "fasthtmlparser/parser"
require_relative "fasthtmlparser/decode"
require_relative "fasthtmlparser/attrs"
require_relative "fasthtmlparser/text"
require_relative "fasthtmlparser/links"
require_relative "fasthtmlparser/query"
require_relative "fasthtmlparser/css"
require_relative "fasthtmlparser/xpath"
require_relative "fasthtmlparser/xpath_compiler"
require_relative "fasthtmlparser/html_node"
require_relative "fasthtmlparser/html_document"
