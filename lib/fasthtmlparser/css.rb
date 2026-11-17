# frozen_string_literal: true

module FastHtmlParser
  # @api private Sibling links and positions of the elements, built once per document by the first selector that
  # needs them.
  class CssTree
    # previous / next element sibling (-1 for none); 1-based position among the element siblings (0: not an
    # element) and from the end
    attr_reader :previous, :next, :position, :from_end

    def initialize(doc)
      @doc = doc
      count = doc.size
      parents = doc.parents
      previous = Array.new(count, -1)
      nxt = Array.new(count, -1)
      position = Array.new(count, 0)
      from_end = Array.new(count, 0)
      # per parent (slot = parent index + 1, slot 0: the top level): its last element child so far and their number
      last_child = Array.new(count + 1, -1)
      children = Array.new(count + 1, 0)
      i = 0
      while i < count
        if CssQuery.element_at?(doc, i)
          slot = parents[i] + 1
          prev = last_child[slot]
          previous[i] = prev
          nxt[prev] = i if prev >= 0
          last_child[slot] = i
          position[i] = children[slot] += 1
        end
        i += 1
      end
      i = 0
      while i < count
        from_end[i] = children[parents[i] + 1] - position[i] + 1 if position[i].positive?
        i += 1
      end
      @previous = previous
      @next = nxt
      @position = position
      @from_end = from_end
      @types = nil
    end

    def prev(n)
      i = @previous[n.index]
      i.negative? ? nil : @doc.at(i)
    end

    def next_of(n)
      i = @next[n.index]
      i.negative? ? nil : @doc.at(i)
    end

    # [position, from_end] among the siblings of the same type
    def type_positions
      return @types if @types

      d = @doc
      count = d.size
      pos = Array.new(count, 0)
      fin = Array.new(count, 0)
      seen = Hash.new(0)
      keys = Array.new(count)
      i = 0
      while i < count
        unless @position[i].zero?
          key = d.keys[i]
          k = [d.parents[i], key, key.negative? ? d.customs[i] : nil]
          keys[i] = k
          pos[i] = seen[k] += 1
        end
        i += 1
      end
      i = 0
      while i < count
        fin[i] = seen[keys[i]] - pos[i] + 1 if pos[i].positive?
        i += 1
      end
      @types = [pos, fin]
    end
  end

  # @api private Parses a selector list (Selectors Level 3 and the common Level 4 pseudo-classes). Identifiers and
  # strings follow the CSS syntax, escapes included (#a\:b, .\31 0, [title="a\"b"]).
  class CssCompiler
    CSS_SPACE = " \t\n\f\r"

    Complex = Struct.new(:lead, :c, :k)
    Compound = Struct.new(:key, :name, :s)

    attr_reader :p

    def initialize(s)
      @s = s
      @n = s.bytesize
      @p = 0
    end

    def fail!(msg)
      raise CssSelectorError, "invalid CSS selector #{Chars.quote(@s)} at position #{@p}: #{msg}"
    end

    def peek(offset)
      i = @p + offset
      i < @n ? @s.getbyte(i) : nil
    end

    def char_at(i)
      Chars.u(@s.byteslice(i, 1))
    end

    def css_space?(c)
      c == 32 || c == 9 || c == 10 || c == 12 || c == 13
    end

    def skip_space
      k = @p
      @p += 1 while @p < @n && css_space?(@s.getbyte(@p))
      @p > k
    end

    def expect(ch)
      if peek(0) != ch.ord
        fail!("'#{ch}' expected") if @p >= @n
        fail!("'#{ch}' expected instead of '#{char_at(@p)}'")
      end
      @p += 1
    end

    # selector-list: complex (',' complex)*
    def parse_list(relative, top_level)
      list = []
      loop do
        list << parse_complex(relative, top_level)
        skip_space
        return list.freeze if peek(0) != 44

        @p += 1
      end
    end

    private

    # complex: [combinator] compound (combinator compound)*
    def parse_complex(relative, top_level)
      skip_space
      cx = Complex.new(CssQuery::COMB_NONE, [], [])
      if relative || top_level
        comb = read_combinator
        if comb != CssQuery::COMB_NONE
          if top_level && comb != CssQuery::COMB_CHILD
            fail!("a selector can start only with '>' (the children of the tag it is called on)")
          end
          cx.lead = comb
        elsif relative
          cx.lead = CssQuery::COMB_DESCENDANT
        end
      end
      cx.c << parse_compound
      loop do
        ws = skip_space
        ch = peek(0)
        return cx.freeze if ch.nil? || ch == 44 || ch == 41 # end, ',' or ')'

        comb = read_combinator
        if comb == CssQuery::COMB_NONE
          fail!("unexpected '#{char_at(@p)}'") unless ws
          comb = CssQuery::COMB_DESCENDANT
        end
        cx.k << comb
        cx.c << parse_compound
      end
    end

    def read_combinator
      comb = case peek(0)
             when 62 then CssQuery::COMB_CHILD
             when 43 then CssQuery::COMB_ADJACENT
             when 126 then CssQuery::COMB_SIBLING
             else CssQuery::COMB_NONE
             end
      if comb != CssQuery::COMB_NONE
        @p += 1
        skip_space
      end
      comb
    end

    # compound: [type | '*'] (#id | .class | [attribute] | :pseudo)*
    def parse_compound
      cp = Compound.new(-1, Chars::EMPTY, [])
      has_type = false
      if peek(0) == 42
        @p += 1
        has_type = true
      elsif ident_start?(@p)
        name = Chars.lower(read_name)
        has_type = true
        t = Parser.lookup_tag(name)
        if t >= 0
          cp.key = t
        else
          cp.name = name.freeze
        end
      end
      fail!("namespaces are not supported; escape the colon of a prefixed name: dc\\:creator") if peek(0) == 124

      loop do
        ch = peek(0)
        if ch == 35
          @p += 1
          fail!("an id expected after '#'") unless name_char?(@p)
          cp.s << CssQuery.id_selector(read_name)
        elsif ch == 46
          @p += 1
          fail!("a class name expected after '.'") unless ident_start?(@p)
          cp.s << CssQuery.class_selector(read_name)
        elsif ch == 91
          cp.s << parse_attribute
        elsif ch == 58
          parse_pseudo(cp)
        else
          break
        end
      end

      if !has_type && cp.s.empty?
        fail!("a selector expected") if @p >= @n
        fail!("unexpected '#{char_at(@p)}'")
      end
      cp.s.freeze
      cp.freeze
    end

    # '[' name [op value [i|s]] ']'
    def parse_attribute
      @p += 1 # '['
      skip_space
      fail!("an attribute name expected") unless ident_start?(@p)
      name = read_name
      skip_space
      if peek(0) == 93
        @p += 1
        return CssQuery.attribute_selector(name, "", Chars::EMPTY, nil)
      end

      ch = peek(0)
      if ch == 61
        op = "="
        @p += 1
      elsif [126, 124, 94, 36, 42].include?(ch)
        op = ch.chr
        fail!("'=' expected after '#{op}'") if peek(1) != 61
        @p += 2
      else
        fail!("'=', '~=', '|=', '^=', '$=', '*=' or ']' expected")
      end

      skip_space
      if peek(0) == 34 || peek(0) == 39
        value = read_string
      elsif ident_start?(@p)
        value = read_name
      else
        fail!("an attribute value expected (quote it if it is not a plain word)")
      end

      skip_space
      flag = nil
      if ident_start?(@p)
        f = read_name
        if Chars.equal_fold(f, "i")
          flag = true
        elsif Chars.equal_fold(f, "s")
          flag = false
        else
          fail!("unknown attribute flag '#{Chars.u(f.dup)}'")
        end
        skip_space
      end
      expect("]")
      CssQuery.attribute_selector(name, op, value, flag)
    end

    def parse_pseudo(cp)
      @p += 1 # ':'
      fail!("pseudo-elements (::before, ::text) select no tags") if peek(0) == 58
      fail!("a pseudo-class name expected after ':'") unless ident_start?(@p)
      start = @p
      name = Chars.lower(read_name)

      if peek(0) == 40
        @p += 1
        skip_space
        case name
        when "not"
          cp.s << CssQuery.logical(:not, parse_list(false, false))
        when "is", "where", "matches", "any"
          cp.s << CssQuery.logical(:is, parse_list(false, false))
        when "has"
          cp.s << CssQuery.logical(:has, parse_list(true, false))
        when "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"
          a, b = parse_nth
          of_type = name.end_with?("of-type")
          of = nil
          skip_space
          if !of_type && word?("of")
            @p += 2
            of = parse_list(false, false)
          end
          cp.s << CssQuery.nth(a, b, name.include?("last"), of_type, of)
        when "contains"
          if peek(0) == 34 || peek(0) == 39
            text = read_string
          elsif ident_start?(@p)
            text = read_name
          else
            fail!("a string expected in :contains()")
          end
          cp.s << CssQuery.contains(text)
        else
          @p = start
          fail!("unknown pseudo-class ':#{Chars.u(name.dup)}()'")
        end
        skip_space
        expect(")")
        return
      end

      case name
      when "first-child"
        cp.s << CssQuery.nth(0, 1, false, false, nil)
      when "last-child"
        cp.s << CssQuery.nth(0, 1, true, false, nil)
      when "only-child"
        cp.s << CssQuery.nth(0, 1, false, false, nil)
        cp.s << CssQuery.nth(0, 1, true, false, nil)
      when "first-of-type"
        cp.s << CssQuery.nth(0, 1, false, true, nil)
      when "last-of-type"
        cp.s << CssQuery.nth(0, 1, true, true, nil)
      when "only-of-type"
        cp.s << CssQuery.nth(0, 1, false, true, nil)
        cp.s << CssQuery.nth(0, 1, true, true, nil)
      else
        pseudo = CssQuery.pseudo(name)
        if pseudo.nil?
          @p = start
          fail!("unknown pseudo-class ':#{Chars.u(name.dup)}'")
        end
        cp.s << pseudo
      end
    end

    # An+B: odd, even, 3, n, -n+3, 2n+1, +2n - 1; [a, b]
    def parse_nth
      if word?("odd")
        @p += 3
        return [2, 1]
      end
      if word?("even")
        @p += 4
        return [2, 0]
      end
      start = @p
      t = +""
      while @p < @n
        ch = @s.getbyte(@p)
        break unless ch == 43 || ch == 45 || ch == 110 || ch == 78 || Chars.digit_byte?(ch) || css_space?(ch)

        t << (ch == 78 ? "n" : ch.chr) unless css_space?(ch)
        @p += 1
      end
      n = t.index("n")
      if n.nil?
        v = parse_int32(t)
        return [0, v] if v
      elsif t.index("n", n + 1).nil?
        a_text = t[0, n]
        b_text = t[(n + 1)..]
        a = if a_text.empty? || a_text == "+"
              1
            else
              a_text == "-" ? -1 : parse_int32(a_text)
            end
        b = 0
        unless b_text.empty?
          ok = (b_text[0] == "+" || b_text[0] == "-") && b_text.size > 1 && Chars.digit_byte?(b_text.getbyte(1))
          b = ok ? parse_int32(b_text) : nil
        end
        return [a, b] if a && b
      end
      @p = start
      fail!("An+B expected (odd, even, 3, 2n+1, -n+3)")
    end

    def parse_int32(s)
      i = !s.empty? && (s[0] == "+" || s[0] == "-") ? 1 : 0
      return nil if i == s.size || !s[i..].match?(/\A[0-9]+\z/)

      digits = s[i..].sub(/\A0+/, "")
      return nil if digits.size > 10

      v = digits.to_i
      v = -v if s[0] == "-"
      v >= -2_147_483_648 && v <= 2_147_483_647 ? v : nil
    end

    # The identifier at the position is word (case-insensitive) and ends there.
    def word?(word)
      len = word.bytesize
      @p + len <= @n && @s.byteslice(@p, len).casecmp?(word) && !name_char?(@p + len)
    end

    def escape?(p)
      return false if p >= @n || @s.getbyte(p) != 92
      return true if p + 1 >= @n

      c = @s.getbyte(p + 1)
      c != 10 && c != 13 && c != 12
    end

    def name_start_byte?(c)
      Chars.alpha_byte?(c) || c == 95 || c >= 0x80
    end

    def name_char?(p)
      return false if p >= @n

      c = @s.getbyte(p)
      name_start_byte?(c) || Chars.digit_byte?(c) || c == 45 || escape?(p)
    end

    def ident_start?(p)
      return false if p >= @n

      if @s.getbyte(p) == 45
        p += 1
        return false if p >= @n

        c = @s.getbyte(p)
        return name_start_byte?(c) || c == 45 || escape?(p)
      end
      name_start_byte?(@s.getbyte(p)) || escape?(p)
    end

    def read_name
      b = String.new(encoding: Encoding::BINARY)
      while name_char?(@p)
        if @s.getbyte(@p) == 92
          b << read_escape
        else
          b << @s.getbyte(@p)
          @p += 1
        end
      end
      b
    end

    def read_string
      quote = @s.getbyte(@p)
      start = @p
      @p += 1
      b = String.new(encoding: Encoding::BINARY)
      loop do
        if @p >= @n
          @p = start
          fail!("unterminated string")
        end
        ch = @s.getbyte(@p)
        if ch == quote
          @p += 1
          return b
        end
        if ch == 92
          nxt = peek(1)
          if @p + 1 < @n && (nxt == 10 || nxt == 12)
            @p += 2 # an escaped line break continues the string
          elsif @p + 2 < @n && nxt == 13
            @p += peek(2) == 10 ? 3 : 2
          else
            b << read_escape
          end
        else
          b << ch
          @p += 1
        end
      end
    end

    # '\' then up to 6 hex digits and one optional whitespace, or any other char as itself.
    def read_escape
      @p += 1 # '\'
      return Chars::REPLACEMENT if @p >= @n

      unless Chars.hex_byte?(@s.getbyte(@p))
        c = @s.getbyte(@p)
        len = if c >= 0xf0 then 4
              elsif c >= 0xe0 then 3
              elsif c >= 0xc0 then 2
              else 1
              end
        ch = @s.byteslice(@p, len)
        @p += ch.bytesize
        return ch
      end
      digits = 0
      digits += 1 while digits < 6 && @p + digits < @n && Chars.hex_byte?(@s.getbyte(@p + digits))
      code = @s.byteslice(@p, digits).to_i(16)
      @p += digits
      if @p < @n && css_space?(@s.getbyte(@p))
        @p += @s.getbyte(@p) == 13 && peek(1) == 10 ? 2 : 1
      end
      return Chars::REPLACEMENT if code.zero? || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)

      Chars.utf8(code)
    end
  end

  # A compiled CSS selector (or a comma-separated list of them), matched right to left over the flat tag list as
  # browsers do. Compile once and reuse it on any number of documents; the string methods (doc.css(...),
  # node.css_first(...), ...) compile and cache selectors automatically.
  #
  # Supported: type, *, #id, .class, attribute selectors ([a], =, ~=, |=, ^=, $=, *=, with the i / s flags), the
  # combinators (descendant, >, +, ~), selector lists and the pseudo-classes :first-child, :last-child, :only-child,
  # :first-of-type, :last-of-type, :only-of-type, :nth-child(An+B [of S]), :nth-last-child(), :nth-of-type(),
  # :nth-last-of-type(), :not(), :is(), :where(), :has(), :empty, :root, :scope, :link, :any-link, :checked,
  # :disabled, :enabled, :required, :optional, and :contains("text"). Pseudo-elements and namespaces are not
  # supported.
  #
  # HTML rules: tag and attribute names are case-insensitive; ids, classes and attribute values are case-sensitive,
  # except the values the HTML standard lists (type, rel, lang, method, ...). Only elements are selected, never
  # comments.
  class CssQuery
    # combinators
    COMB_NONE = 0
    COMB_DESCENDANT = 1 # "a b"
    COMB_CHILD = 2 # "a > b"
    COMB_ADJACENT = 3 # "a + b"
    COMB_SIBLING = 4 # "a ~ b"

    # simple selectors: [kind, ...]
    S_ID = 0 # [S_ID, id]
    S_CLASS = 1 # [S_CLASS, name]
    S_ATTR = 2 # [S_ATTR, name, op, value, fold]
    S_NTH = 3 # [S_NTH, a, b, from_end, of_type, of (a list or nil)]
    S_NOT = 4 # [S_NOT, list]
    S_IS = 5 # [S_IS, list]
    S_HAS = 6 # [S_HAS, list]
    S_CONTAINS = 7 # [S_CONTAINS, text]
    S_PSEUDO = 8 # [S_PSEUDO, kind]

    OP_EXISTS = 0 # [a]
    OP_EQUALS = 1 # [a=v]
    OP_INCLUDES = 2 # [a~=v]
    OP_DASH = 3 # [a|=v]
    OP_PREFIX = 4 # [a^=v]
    OP_SUFFIX = 5 # [a$=v]
    OP_SUBSTRING = 6 # [a*=v]

    PSEUDO_ROOT = 0
    PSEUDO_SCOPE = 1
    PSEUDO_EMPTY = 2
    PSEUDO_LINK = 3
    PSEUDO_CHECKED = 4
    PSEUDO_DISABLED = 5
    PSEUDO_ENABLED = 6
    PSEUDO_REQUIRED = 7
    PSEUDO_OPTIONAL = 8

    COMMENT = TagNames::KEYS["!--"]
    DOCTYPE = TagNames::KEYS["!doctype"]
    XML_DECLARATION = TagNames::KEYS["?xml"]

    CSS_SPACE_RE = /[ \t\n\f\r]/n

    # HTML: the values of these attributes are compared ignoring ASCII case unless the selector has the 's' flag.
    CASE_INSENSITIVE_VALUES = %w[accept accept-charset align alink axis bgcolor charset checked clear codetype color
                                 compact declare defer dir direction disabled enctype face frame hreflang http-equiv
                                 lang language link media method multiple nohref noresize noshade nowrap readonly rel
                                 rev rules scope scrolling selected shape target text type valign valuetype
                                 vlink].to_h { |n| [n, true] }.freeze

    FORM_CONTROLS = %w[button input select textarea optgroup option fieldset].to_h { |n| [n, true] }.freeze
    INPUTS = %w[input select textarea].to_h { |n| [n, true] }.freeze

    @cache = {}
    @cache_lock = Mutex.new

    # A selector list is a list of complex selectors (lead combinator, compounds c, combinators k: k[i] stands
    # between c[i] and c[i+1]). A compound is (Tag key or -1, custom name ("": any element when key is -1), simple
    # selectors).
    def initialize(selector, list)
      @selector = selector
      @list = list
      # the name of the rightmost compound of each selector, checked on the arrays before a tag object is made
      names = []
      list.each do |item|
        last = item.c[-1]
        if last.key.negative? && last.name.empty?
          names = nil # any element
          break
        end
        names << last
      end
      @names = names
      freeze
    end

    # Compiles a CSS selector; raises CssSelectorError on an invalid one.
    def self.compile(selector)
      s = Chars.b(selector.to_s)
      c = CssCompiler.new(s)
      list = c.parse_list(false, true)
      c.fail!("unexpected '#{Chars.u(s.byteslice(c.p, 1))}'") if c.p < s.bytesize
      new(selector.to_s.dup.freeze, list)
    end

    # @api private compiles and caches
    def self.cached(selector)
      q = @cache[selector]
      return q if q

      q = compile(selector)
      @cache_lock.synchronize do
        @cache.clear if @cache.size >= 1024 # dynamically built selectors must not grow the cache forever
        @cache[selector.frozen? ? selector : selector.dup.freeze] = q
      end
      q
    end

    # The source of the selector.
    attr_reader :selector

    def to_s
      @selector
    end

    def inspect
      "#<#{self.class.name} #{@selector}>"
    end

    # The matching tags in the document, in document order.
    def all(doc)
      scan(doc, nil, 0, Float::INFINITY, false)
    end

    # The first matching tag in the document, or nil.
    def first(doc)
      scan(doc, nil, 0, Float::INFINITY, true).first
    end

    # The matching tags inside the tag (as querySelectorAll).
    def all_in(node)
      scan(node.doc, node, node.index + 1, node.end, false)
    end

    # The first matching tag inside the tag, or nil.
    def first_in(node)
      scan(node.doc, node, node.index + 1, node.end, true).first
    end

    # Whether the tag matches (as element.matches(): :scope is the tag itself); false for comments and nil.
    def matches?(node)
      !node.nil? && CssQuery.element?(node) && CssQuery.matches_list?(@list, node, node, node)
    end

    # @api private Not a comment, the doctype or the XML declaration.
    def self.element?(n)
      key = n.key
      return key != COMMENT && key != DOCTYPE && key != XML_DECLARATION if key >= 0

      custom = n.custom
      !custom.empty? && custom.getbyte(0) != 33 && custom.getbyte(0) != 63
    end

    # @api private element? for the tag at index i
    def self.element_at?(d, i)
      key = d.keys[i]
      return key != COMMENT && key != DOCTYPE && key != XML_DECLARATION if key >= 0

      custom = d.customs[i]
      !custom.empty? && custom.getbyte(0) != 33 && custom.getbyte(0) != 63
    end

    private

    def scan(d, scope, from, end_, first_only)
      out = []
      ends = d.ends
      keys = d.keys
      customs = d.customs
      list = @list
      names = @names
      # one selector with a known tag name: one int compare per tag
      single = names && names.size == 1 && names[0].key >= 0 ? names[0].key : nil
      count = d.size
      i = from
      while i < count
        break if ends[i] > end_

        if single
          if keys[i] != single
            i += 1
            next
          end
        elsif names
          k = keys[i]
          candidate = false
          j = 0
          while j < names.size
            cp = names[j]
            if cp.key >= 0 ? k == cp.key : k < 0 && customs[i] == cp.name
              candidate = true
              break
            end
            j += 1
          end
          unless candidate
            i += 1
            next
          end
        elsif !CssQuery.element_at?(d, i)
          i += 1
          next
        end
        n = d.at(i)
        if CssQuery.matches_list?(list, n, scope, scope)
          out << n
          break if first_only
        end
        i += 1
      end
      out
    end

    class << self
      # ----- matching -----

      # scope: the tag the query was called on (:scope, nil for the document); anchor: the tag a relative selector
      # starts from (:has(> a), or node.css("> li"); nil: the document).
      def matches_list?(list, n, scope, anchor)
        i = 0
        while i < list.size
          item = list[i]
          return true if matches_complex?(item, item.c.size - 1, n, scope, anchor)

          i += 1
        end
        false
      end

      # n matches compound i and the part to the left of it matches the tags the combinators lead to.
      def matches_complex?(cx, i, n, scope, anchor)
        return false unless matches_compound?(cx.c[i], n, scope, anchor)
        return cx.lead == COMB_NONE || related?(cx.lead, anchor, n) if i.zero?

        case cx.k[i - 1]
        when COMB_CHILD
          p = n.parent
          !p.nil? && matches_complex?(cx, i - 1, p, scope, anchor)
        when COMB_DESCENDANT
          p = n.parent
          until p.nil?
            return true if matches_complex?(cx, i - 1, p, scope, anchor)

            p = p.parent
          end
          false
        when COMB_ADJACENT
          p = n.doc.css_tree.prev(n)
          !p.nil? && matches_complex?(cx, i - 1, p, scope, anchor)
        when COMB_SIBLING
          t = n.doc.css_tree
          p = t.prev(n)
          until p.nil?
            return true if matches_complex?(cx, i - 1, p, scope, anchor)

            p = t.prev(p)
          end
          false
        else
          false
        end
      end

      def matches_compound?(cp, n, scope, anchor)
        if cp.key >= 0
          return false if n.key != cp.key
        elsif !cp.name.empty?
          return false if n.key >= 0 || n.custom != cp.name
        elsif !element?(n)
          return false
        end
        simple = cp.s
        i = 0
        while i < simple.size
          return false unless matches_simple?(simple[i], n, scope, anchor)

          i += 1
        end
        true
      end

      # n stands in the combinator relation to anchor (nil: the document).
      def related?(c, anchor, n)
        case c
        when COMB_CHILD
          anchor.nil? ? n.parent_index.negative? : n.parent_index == anchor.index
        when COMB_DESCENDANT
          return true if anchor.nil?

          p = n.parent
          until p.nil?
            return true if p.equal?(anchor)

            p = p.parent
          end
          false
        when COMB_ADJACENT
          !anchor.nil? && n.doc.css_tree.prev(n).equal?(anchor)
        when COMB_SIBLING
          !anchor.nil? && anchor.index < n.index && anchor.parent_index == n.parent_index && element?(anchor)
        else
          false
        end
      end

      # :has(): whether a tag in the anchor's scope matches the relative selector.
      def has_match?(relative, anchor, scope)
        d = anchor.doc
        ends = d.ends
        count = d.size
        relative.each do |item|
          last = item.c.size - 1
          i = anchor.index + 1
          if item.lead == COMB_DESCENDANT || item.lead == COMB_CHILD
            # the tags inside the anchor
            while i < count && ends[i] <= anchor.end
              return true if element_at?(d, i) && matches_complex?(item, last, d.at(i), scope, anchor)

              i += 1
            end
          else
            # the following siblings and the tags inside them, up to the end of the parent
            i += 1 while i < count && ends[i] <= anchor.end
            end_ = anchor.parent_index >= 0 ? ends[anchor.parent_index] : Float::INFINITY
            while i < count && ends[i] <= end_
              return true if element_at?(d, i) && matches_complex?(item, last, d.at(i), scope, anchor)

              i += 1
            end
          end
        end
        false
      end

      # Whether a whitespace-separated list contains word.
      def contains_word?(list, word, fold)
        return false if word.empty? || list.bytesize < word.bytesize
        return list == word if !fold && !CSS_SPACE_RE.match?(list)

        list.split(CSS_SPACE_RE).any? { |w| !w.empty? && equal?(w, word, fold) }
      end

      def equal?(a, b, fold)
        fold ? Chars.equal_fold(a, b) : a == b
      end

      def decoded(raw)
        Decode.needs_decoding?(raw) ? Decode.decode(raw, true) : raw
      end

      def matches_simple?(s, n, scope, anchor)
        case s[0]
        when S_ID
          Attrs.attr_equals?(Attrs.attr_raw(n, Attrs::ID), s[1])
        when S_CLASS
          raw = Attrs.attr_raw(n, Attrs::CLASS)
          !raw.empty? && contains_word?(decoded(raw), s[1], false)
        when S_ATTR
          matches_attribute?(n, s[1], s[2], s[3], s[4])
        when S_NTH
          matches_nth?(n, s[1], s[2], s[3], s[4], s[5], scope, anchor)
        when S_NOT
          !matches_list?(s[1], n, scope, anchor)
        when S_IS
          matches_list?(s[1], n, scope, anchor)
        when S_HAS
          has_match?(s[1], n, scope)
        when S_CONTAINS
          n.text_bytes.include?(s[1])
        else
          matches_pseudo?(s[1], n, scope)
        end
      end

      def matches_attribute?(n, name, op, v, fold)
        raw = Attrs.attr_raw(n, name)
        if raw.empty?
          # missing or empty: only these can match an empty value
          return Attrs.has_attribute?(n, name) if op == OP_EXISTS
          return v.empty? && Attrs.has_attribute?(n, name) if op == OP_EQUALS || op == OP_DASH

          return false
        end
        return true if op == OP_EXISTS

        actual = decoded(raw)
        vl = v.bytesize
        case op
        when OP_EQUALS
          equal?(actual, v, fold)
        when OP_INCLUDES
          !CSS_SPACE_RE.match?(v) && contains_word?(actual, v, fold)
        when OP_DASH
          equal?(actual, v, fold) ||
            (actual.bytesize > vl && actual.getbyte(vl) == 45 && equal?(actual.byteslice(0, vl), v, fold))
        when OP_PREFIX
          !v.empty? && actual.bytesize >= vl && equal?(actual.byteslice(0, vl), v, fold)
        when OP_SUFFIX
          !v.empty? && actual.bytesize >= vl && equal?(actual.byteslice(actual.bytesize - vl, vl), v, fold)
        when OP_SUBSTRING
          return false if v.empty?
          return actual.include?(v) unless fold
          return actual.downcase(:ascii).include?(v.downcase(:ascii)) if v.ascii_only?

          Chars.lower(actual).include?(Chars.lower(v))
        else
          false
        end
      end

      # :nth-child(An+B [of S]) and its relatives; :first-child is :nth-child(1), and so on.
      def matches_nth?(n, a, b, from_end, of_type, of, scope, anchor)
        t = n.doc.css_tree
        if of
          return false unless matches_list?(of, n, scope, anchor)

          position = 1
          sib = from_end ? t.next_of(n) : t.prev(n)
          until sib.nil?
            position += 1 if matches_list?(of, sib, scope, anchor)
            sib = from_end ? t.next_of(sib) : t.prev(sib)
          end
        elsif of_type
          tp = t.type_positions
          position = from_end ? tp[1][n.index] : tp[0][n.index]
        else
          position = from_end ? t.from_end[n.index] : t.position[n.index]
        end
        return false if position <= 0 # not an element

        # position = a*n + b for some n >= 0
        return position == b if a.zero?

        diff = position - b
        (diff % a).zero? && (diff / a) >= 0
      end

      # the first top-level element: <html> on a page
      def root?(n)
        n.parent_index.negative? && n.doc.css_tree.prev(n).nil?
      end

      # No child elements and no text; comments are allowed.
      def empty_element?(n)
        return true if n.inner_start <= 0 || n.inner_end <= 0 # a void or unclosed tag has no content

        position = n.inner_start
        d = n.doc
        ends = d.ends
        starts = d.starts
        i = n.index + 1
        count = d.size
        while i < count && ends[i] <= n.end
          return false if element_at?(d, i) || starts[i] > position # an element, or text before a comment

          position = ends[i] + 1 if ends[i] + 1 > position
          i += 1
        end
        position > n.inner_end
      end

      def matches_pseudo?(kind, n, scope)
        name = n.name_bytes
        case kind
        when PSEUDO_ROOT then root?(n)
        when PSEUDO_SCOPE then scope.nil? ? root?(n) : n.equal?(scope)
        when PSEUDO_EMPTY then empty_element?(n)
        when PSEUDO_LINK then (name == "a" || name == "area") && Attrs.has_attribute?(n, "href")
        when PSEUDO_CHECKED
          (name == "input" && Attrs.has_attribute?(n, "checked")) ||
            (name == "option" && Attrs.has_attribute?(n, "selected"))
        when PSEUDO_DISABLED then FORM_CONTROLS.key?(name) && Attrs.has_attribute?(n, "disabled")
        when PSEUDO_ENABLED then FORM_CONTROLS.key?(name) && !Attrs.has_attribute?(n, "disabled")
        when PSEUDO_REQUIRED then INPUTS.key?(name) && Attrs.has_attribute?(n, "required")
        when PSEUDO_OPTIONAL then INPUTS.key?(name) && !Attrs.has_attribute?(n, "required")
        else false
        end
      end

      # ----- the parts the compiler builds -----

      def id_selector(id)
        [S_ID, id.freeze].freeze
      end

      def class_selector(name)
        [S_CLASS, name.freeze].freeze
      end

      # op: "" (exists), "=", "~", "|", "^", "$", "*"
      def attribute_selector(name, op, value, flag)
        code = case op
               when "" then OP_EXISTS
               when "=" then OP_EQUALS
               when "~" then OP_INCLUDES
               when "|" then OP_DASH
               when "^" then OP_PREFIX
               when "$" then OP_SUFFIX
               else OP_SUBSTRING
               end
        lname = Chars.lower(name)
        fold = flag.nil? ? CASE_INSENSITIVE_VALUES.key?(lname) : flag
        [S_ATTR, name.downcase(:ascii).freeze, code, value.freeze, op == "" ? false : fold].freeze
      end

      def nth(a, b, from_end, of_type, of)
        [S_NTH, a, b, from_end, of_type, of].freeze
      end

      # kind: :not, :is, :has
      def logical(kind, list)
        [kind == :not ? S_NOT : (kind == :has ? S_HAS : S_IS), list].freeze
      end

      def contains(text)
        [S_CONTAINS, text.freeze].freeze
      end

      # a pseudo-class without arguments, or nil for an unknown one
      def pseudo(name)
        kind = case name
               when "root" then PSEUDO_ROOT
               when "scope" then PSEUDO_SCOPE
               when "empty" then PSEUDO_EMPTY
               when "link", "any-link" then PSEUDO_LINK
               when "checked" then PSEUDO_CHECKED
               when "disabled" then PSEUDO_DISABLED
               when "enabled" then PSEUDO_ENABLED
               when "required" then PSEUDO_REQUIRED
               when "optional" then PSEUDO_OPTIONAL
               end
        kind.nil? ? nil : [S_PSEUDO, kind].freeze
      end
    end
  end
end
