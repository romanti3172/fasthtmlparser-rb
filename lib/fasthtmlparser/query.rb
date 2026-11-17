# frozen_string_literal: true

module FastHtmlParser
  # Selects tags by name and, optionally, class, id, attribute value, visible text, inner HTML and the source of the
  # opening tag. Queries are immutable: every method returns a new one. Start with Query.by(:div),
  # Query.by("my-widget") or Query.any.
  #
  #   doc.find_all(Query.by(:article).has_class("product_pod"))
  #   pod.find(Query.by(:p).has_class("price_color")).text
  class Query
    SYMBOL_KEYS = TagNames::NAMES.each_with_index.to_h { |n, i| [n.to_sym, i] }.freeze

    # @api private Tag key, or -1: by name (tag_name) or any (tag_name "")
    attr_reader :key
    # @api private the name as given (binary); "" for a known Symbol and for any
    attr_reader :tag_name

    # @api private Use Query.by or Query.any.
    def initialize(key, tag_name, plain, cls, id, attr_name, attr_value, text, id_starts_with, text_starts_with, body,
                   body_starts_with, source)
      @key = key
      @tag_name = tag_name
      @class = cls
      @id = id
      @attr_name = attr_name
      @attr_value = attr_value
      @text = text
      @id_starts_with = id_starts_with
      @text_starts_with = text_starts_with
      @body = body
      @body_starts_with = body_starts_with
      @source = source
      @plain = plain # no criteria but the name
      freeze
    end

    # Selects tags by name, case-insensitively: a Tag symbol (:div), or any name as a String or Symbol.
    def self.by(name)
      if name.is_a?(Symbol)
        q = BY_SYMBOL[name]
        return q if q

        name = name.to_s
      end
      n = Query.value(name)
      new(Parser.lookup_tag(n), n, true, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    end

    ANY = new(-1, Chars::EMPTY, true, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    BY_SYMBOL = SYMBOL_KEYS.transform_values do |k|
      new(k, Chars::EMPTY, true, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    end.freeze

    # Selects every tag.
    def self.any
      ANY
    end

    # @api private A criterion as the library compares it: frozen, binary when it is not ASCII.
    def self.value(s)
      return s if s.frozen? && s.ascii_only?

      s = s.to_s unless s.is_a?(String)
      return s.dup.freeze if s.ascii_only?

      s.b.freeze
    end

    # Adds a class criterion: one of the space-separated classes, case-insensitive.
    def has_class(cls)
      Query.new(@key, @tag_name, false, Query.value(cls), @id, @attr_name, @attr_value, @text, @id_starts_with,
                @text_starts_with, @body, @body_starts_with, @source)
    end

    # Adds an id criterion.
    def id(id)
      Query.new(@key, @tag_name, false, @class, Query.value(id), @attr_name, @attr_value, @text, @id_starts_with,
                @text_starts_with, @body, @body_starts_with, @source)
    end

    # Adds an attribute criterion: the decoded value equals value.
    def attr(name, value)
      Query.new(@key, @tag_name, false, @class, @id, Query.value(name).downcase(:ascii).freeze, Query.value(value), @text,
                @id_starts_with, @text_starts_with, @body, @body_starts_with, @source)
    end

    # Adds a visible-text criterion (see HtmlNode#text).
    def text(text)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, Query.value(text), @id_starts_with,
                @text_starts_with, @body, @body_starts_with, @source)
    end

    # Adds a criterion: the decoded id starts with prefix.
    def id_starts_with(prefix)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, @text, Query.value(prefix),
                @text_starts_with, @body, @body_starts_with, @source)
    end

    # Adds a criterion: the visible text starts with prefix.
    def text_starts_with(prefix)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, @text, @id_starts_with, Query.value(prefix),
                @body, @body_starts_with, @source)
    end

    # Adds a criterion: the inner HTML (trimmed) equals body.
    def body(body)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, @text, @id_starts_with, @text_starts_with,
                Query.value(body), @body_starts_with, @source)
    end

    # Adds a criterion: the inner HTML (trimmed) starts with prefix.
    def body_starts_with(prefix)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, @text, @id_starts_with, @text_starts_with,
                @body, Query.value(prefix), @source)
    end

    # Adds a criterion: the opening tag without '<' and '>' (see HtmlNode#source) equals source.
    def source(source)
      Query.new(@key, @tag_name, false, @class, @id, @attr_name, @attr_value, @text, @id_starts_with, @text_starts_with,
                @body, @body_starts_with, Query.value(source))
    end

    # Whether the tag matches every criterion; false for nil.
    def matches?(n)
      !n.nil? && name_matches_at?(n.doc, n.index) && (@plain || matches_more?(n))
    end

    # @api private The first tag from index from on that matches, up to the tags that end after end_; or nil.
    def find_in(d, from, end_)
      scan(d, from, end_, true).first
    end

    # @api private All tags from index from on that match, up to the tags that end after end_.
    def find_all_in(d, from, end_)
      scan(d, from, end_, false)
    end

    # @api private Whether the tag at index i has the name of the query.
    def name_matches_at?(d, i)
      if @key >= 0
        k = d.keys[i]
        return k == @key || (k.negative? && !@tag_name.empty? && Chars.equal_fold(d.customs[i], @tag_name))
      end
      return true if @tag_name.empty?

      k = d.keys[i]
      Chars.equal_fold(k >= 0 ? TagNames::NAMES[k] : d.customs[i], @tag_name)
    end

    # @api private The older "optional" shortcuts skip an empty criterion.
    def self.opt_class(q, cls)
      cls.empty? ? q : q.has_class(cls)
    end

    # @api private
    def self.opt_id(q, id)
      id.empty? ? q : q.id(id)
    end

    # @api private
    def self.opt_text(q, text)
      text.empty? ? q : q.text(text)
    end

    # @api private
    def self.opt_body(q, body)
      body.empty? ? q : q.body(body)
    end

    private

    def scan(d, from, end_, first_only)
      out = []
      ends = d.ends
      keys = d.keys
      key = @key
      plain = @plain
      named = !@tag_name.empty?
      count = d.size
      i = from
      while i < count
        break if ends[i] > end_

        # the name on the arrays first (a known name: one int compare), the tag object only for a candidate
        if key >= 0
          k = keys[i]
          if k != key && (k >= 0 || !named || !Chars.equal_fold(d.customs[i], @tag_name))
            i += 1
            next
          end
        elsif named && !name_matches_at?(d, i)
          i += 1
          next
        end
        n = d.at(i)
        if plain || matches_more?(n)
          out << n
          break if first_only
        end
        i += 1
      end
      out
    end

    # The criteria other than the name.
    def matches_more?(n)
      return false if @id && (@id.empty? || !Attrs.attr_equals?(Attrs.attr_raw(n, Attrs::ID), @id))
      return false if @attr_name && !Attrs.attr_equals?(Attrs.attr_raw(n, @attr_name), @attr_value)
      return false if @class && !Attrs.has_class?(n, @class)
      return false if @id_starts_with && !Attrs.attr_starts_with?(Attrs.attr_raw(n, Attrs::ID), @id_starts_with)
      return false if @source && n.source_bytes != @source
      return false if @body && n.body_bytes != @body
      return false if @body_starts_with && !n.body_bytes.start_with?(@body_starts_with)
      # the text last: it is the most expensive check
      return false if @text && !Text.text?(n.body_bytes, @text, n)
      return false if @text_starts_with && !n.text_bytes.start_with?(@text_starts_with)

      true
    end
  end
end
