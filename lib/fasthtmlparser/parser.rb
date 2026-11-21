# frozen_string_literal: true

require "strscan"

module FastHtmlParser
  # @api private A page is scanned once in fast mode: tags are matched to their end tags and nothing else.
  # Well-formed markup needs nothing more. Where the HTML5 optional-end-tag rules matter (<li>one<li>two</ul>), tags
  # are left open inside an element: when its end tag (or the end of the document) finds them on the stack and one of
  # them is a rule target (li, p, td, tr, option, ...), only that part is scanned again in rules mode, from the
  # outermost such tag up to that end tag. Everything before it was parsed right and is kept.
  #
  # Port of ParsingCore.cs from z3l.FastHtmlParser; positions are byte offsets into the UTF-8 source.
  class Parser
    # Nesting deeper than this is flattened, as browsers do (Blink: 512).
    MAX_DEPTH = 512
    # The parts scanned again with the optional-end-tag rules may add up to this many times the source length.
    REPAIR_BUDGET_FACTOR = 8

    KEYS = TagNames::KEYS
    NAMES = TagNames::NAMES
    COMMENT = KEYS["!--"]
    P = KEYS["p"]

    # "</script", "</style", ... by tag key, for the elements whose content is raw text (HTML5 RAWTEXT / RCDATA).
    RAW_TEXT_ENDS = Array.new(NAMES.size)
    %w[script style textarea title xmp iframe noembed noframes].each do |n|
      RAW_TEXT_ENDS[KEYS[n]] = "</#{n}".b.freeze
    end
    RAW_TEXT_ENDS.freeze

    # HTML5 void elements (incl. obsolete ones the parsing rules also treat as void) and declarations.
    VOID_NAMES = %w[area base br col embed hr img input link meta source track wbr basefont bgsound frame keygen param
                    isindex !doctype ?xml].freeze

    # Elements that limit the scope of the rules (HTML5 "has an element in scope").
    SCOPE_STOPS = %w[html body table caption td th template object applet marquee button].freeze

    # <p> is ended by the start of a block element (HTML5 "close a p element").
    CLOSES_P_NAMES = %w[address article aside blockquote center details dialog dir div dl fieldset figcaption figure
                        footer form h1 h2 h3 h4 h5 h6 header hgroup hr listing main menu nav ol p pre search section
                        summary table ul li dd dt plaintext xmp].freeze

    # per tag key: what the parser does with it
    F_VOID = 1
    F_CLOSES_P = 2
    F_RULE = 4
    F_RAW_TEXT = 8

    # A rule: t (targets) and s (stops) as flags by tag key, k: the target keys.
    Rule = Struct.new(:t, :s, :k)

    def self.rule(targets, *stops)
      t = Array.new(NAMES.size, false)
      s = Array.new(NAMES.size, false)
      targets.each { |n| t[KEYS[n]] = true }
      stops.each { |list| list.each { |n| s[KEYS[n]] = true } }
      Rule.new(t.freeze, s.freeze, targets.map { |n| KEYS[n] }.freeze).freeze
    end
    private_class_method :rule

    P_RULE = rule(%w[p], SCOPE_STOPS)

    RULES = Array.new(NAMES.size)
    RULES[KEYS["li"]] = rule(%w[li], SCOPE_STOPS, %w[ul ol menu])
    RULES[KEYS["dt"]] = RULES[KEYS["dd"]] = rule(%w[dt dd], SCOPE_STOPS, %w[dl])
    table_stops = %w[html body template table]
    RULES[KEYS["td"]] = RULES[KEYS["th"]] = rule(%w[td th], table_stops, %w[tr tbody thead tfoot])
    RULES[KEYS["tr"]] = rule(%w[tr td th], table_stops, %w[tbody thead tfoot])
    section = rule(%w[tbody thead tfoot tr td th caption], table_stops)
    RULES[KEYS["tbody"]] = RULES[KEYS["thead"]] = RULES[KEYS["tfoot"]] = section
    select_stops = %w[html body template select datalist]
    RULES[KEYS["option"]] = rule(%w[option], select_stops, %w[optgroup])
    RULES[KEYS["optgroup"]] = rule(%w[option optgroup], select_stops)
    RULES.freeze

    FLAGS = Array.new(NAMES.size, 0)
    VOID_NAMES.each { |n| FLAGS[KEYS[n]] |= F_VOID }
    CLOSES_P_NAMES.each { |n| FLAGS[KEYS[n]] |= F_CLOSES_P }
    RAW_TEXT_ENDS.each_with_index { |e, k| FLAGS[k] |= F_RAW_TEXT if e }
    RULES.each_with_index { |r, k| FLAGS[k] |= F_RULE if r }
    FLAGS.freeze

    IS_RULE_TARGET = Array.new(NAMES.size, false)
    RULES.each { |r| r&.k&.each { |k| IS_RULE_TARGET[k] = true } }
    IS_RULE_TARGET.freeze

    # Inside a tag only '<', '=' and '>' matter; a quoted value after '=' may contain '<' and '>' (data-x="<p>").
    TAG_BODY = /(?>[^<>=]++|=[\t-\r ]*+(?>"[^"]*+"|'[^']*+')?)*+/n
    # A tag name ends at whitespace or '/' (<br/> is "br", as <br /> is). On the way to the end of the tag it is read
    # up to '<', '=' or '>' too (TAG_BODY reads what follows); no match when it runs into '=' (read byte by byte then).
    NAME_PART = %r{[^\t-\r /<=>]*+(?!=)}n
    LT = "<"
    RAW_TEXT_END_PATTERNS = {}
    RAW_TEXT_ENDS.each { |e| RAW_TEXT_END_PATTERNS[e] = Regexp.new(Regexp.escape(e), Regexp::IGNORECASE | Regexp::NOENCODING) if e }
    RAW_TEXT_END_PATTERNS.freeze

    # Finds the tag name s[from, to) case-insensitively (ASCII); -1 for a name that is not a known tag.
    def self.lookup_tag_at(s, from, to)
      length = to - from
      return -1 if length <= 0 || length > 32

      KEYS[s.byteslice(from, length).downcase(:ascii)] || -1
    end

    # Finds a tag name case-insensitively (ASCII); -1 for a name that is not a known tag.
    def self.lookup_tag(name)
      return -1 if name.empty? || name.bytesize > 32

      KEYS[name] || KEYS[name.downcase(:ascii)] || -1
    end

    # Whether the content of the tag is raw text (script, style, textarea, title, ...).
    def self.raw_text?(key)
      key >= 0 && !RAW_TEXT_ENDS[key].nil?
    end

    # As in HTML5, '<' starts markup only before an ASCII letter, '/', '!' or '?'.
    def self.markup_start?(s, i, limit)
      return false if i + 1 >= limit

      c = s.getbyte(i + 1)
      ((c | 0x20) >= 97 && (c | 0x20) <= 122) || c == 47 || c == 33 || c == 63
    end

    # The position of the '<' of the end tag (e.g. "</script") in s[from, limit), or limit if there is none.
    def self.find_raw_text_end(s, from, end_tag, limit)
      n = end_tag.bytesize
      re = RAW_TEXT_END_PATTERNS[end_tag] || Regexp.new(Regexp.escape(end_tag), Regexp::IGNORECASE | Regexp::NOENCODING)
      while from < limit
        pos = s.index(re, from)
        break if pos.nil? || pos + n > limit

        after = pos + n
        # "</script>", "</script >", "</script/>" end it; "</scripts" does not.
        return pos if after >= limit

        c = s.getbyte(after)
        return pos if c == 62 || c == 47 || c == 32 || (c >= 9 && c <= 13)

        from = after
      end
      limit
    end

    # The position of the '>' that ends a comment whose content starts at content_start (in s[0, limit)). As in
    # HTML5: "<!-->" and "<!--->" are empty comments, "-->" or "--!>" end a comment, otherwise it runs to the end.
    def self.find_comment_end(s, content_start, limit)
      return content_start if content_start < limit && s.getbyte(content_start) == 62
      if content_start + 1 < limit && s.getbyte(content_start) == 45 && s.getbyte(content_start + 1) == 62
        return content_start + 1
      end

      from = content_start
      len = s.bytesize
      while from < limit
        dashes = from < len ? s.index("--", from) : nil
        break if dashes.nil? || dashes + 2 > limit

        pos = dashes + 2
        return pos if pos < limit && s.getbyte(pos) == 62
        return pos + 1 if pos + 1 < limit && s.getbyte(pos) == 33 && s.getbyte(pos + 1) == 62

        from = dashes + 1
      end
      limit - 1
    end

    # An XML document (RSS, Atom, sitemap, XHTML) is parsed by XML rules: elements end only with an end tag or "/>".
    def self.xml?(src)
      i = 0
      n = src.bytesize
      loop do
        i += 1 while i < n && Chars.space_byte?(src.getbyte(i))
        if i + 3 <= n && src.getbyte(i) == 0xef && src.getbyte(i + 1) == 0xbb && src.getbyte(i + 2) == 0xbf
          i += 3 # a BOM
          next
        end
        break
      end
      n - i >= 5 && src.getbyte(i) == 60 && src.getbyte(i + 1) == 63 && Chars.starts_with_fold?(src, i, "<?xml")
    end

    # Parses src (binary) into the flat tag list: the tags in document order as parallel arrays
    # [keys, custom names, parents, depths, starts, ends, inner starts, inner ends].
    def self.parse_tags(src)
      return Array.new(8) { [] } unless src.include?("<")

      st = new(src)
      st.scan_fast
      st.finish
    end

    def initialize(src)
      @src = src
      @ss = StringScanner.new(src)
      @is_xml = Parser.xml?(src)
      @budget = REPAIR_BUDGET_FACTOR * src.bytesize # bytes that may still be scanned again by repair
      @key = [] # Tag key, or -1 for a custom name
      @customs = [] # the lower-case name of a tag that is not in Tag, "" for the others
      @parents = [] # the index of the enclosing tag, -1 at the top level
      @starts = [] # the opening '<'
      @ends = [] # the last '>': of the end tag, or of the opening tag
      @inner_starts = [] # right after the opening tag
      @inner_ends = [] # the last byte before the end tag; 0 when the tag is not closed
      @depth = []
      @prev_open = [] # the open tags as a linked list in document order
      @self_closed = [] # <x/>: stays in the open list (a later </x> ends it), but nests nothing
      @stack = [] # indexes of the open tags that contain the following ones
      @open_by_key = Array.new(NAMES.size, 0) # per Tag, how many are on the stack: kept only in rules mode
      @open_in_list = Array.new(NAMES.size, 0) # per Tag, how many are in the open list
      @custom_open = {} # custom names (lower case): how many such tags are in the open list
      @count = 0
      @stack_top = 0
      @last_open = -1
      @open_p = 0 # <p> tags on the stack, kept in both modes
      @tag_started = false # scan results
      @tag_start = 0
    end

    # The end of the document ends every tag still open (a truncated page keeps its text), right before an unfinished
    # tag if the source stops inside one. Returns the arrays.
    def finish
      region_end = @tag_started ? @tag_start - 1 : @src.bytesize
      unless @is_xml
        s = first_misnested(0, @stack_top)
        repair(s, region_end) if s >= 0
      end
      truncate_open_list(0, region_end - 1)

      out = [@key, @customs, @parents, @depth, @starts, @ends, @inner_starts, @inner_ends]
      count = @count
      out.each { |a| a.slice!(count..) } if count < @key.size
      inner_starts = @inner_starts
      @inner_ends.each_with_index { |e, k| inner_starts[k] = 0 if e == 0 } # not closed: no body
      out
    end

    # The first scan of the whole page in fast mode: what scan(false, 0, size) does, with the common cases inline and
    # the state in local variables (a method call and an instance variable cost several plain operations). Whatever
    # the inline code does not handle (comments, custom names, the optional-end-tag rules, a misnested end tag, an
    # unfinished tag) is handed to the general code with the state written back.
    def scan_fast
      src = @src
      ss = @ss
      to = src.bytesize
      keys = @key
      customs = @customs
      parents = @parents
      depths = @depth
      starts = @starts
      ends = @ends
      inner_starts = @inner_starts
      inner_ends = @inner_ends
      prev_open = @prev_open
      self_closed = @self_closed
      stack = @stack
      open_in_list = @open_in_list
      is_xml = @is_xml
      empty = Chars::EMPTY
      count = 0
      stack_top = 0
      last_open = -1
      open_p = 0
      i = 0
      while i < to
        lt = src.index(LT, i)
        break if lt.nil?

        i = lt
        break if i + 1 >= to

        c = src.getbyte(i + 1)
        tag_start = i + 1
        ss.pos = tag_start
        if c == 47
          p = tag_start + ss.skip(TAG_BODY)
          if p < to && src.getbyte(p) == 62
            name = src.byteslice(tag_start + 1, p - tag_start - 1)
            key = KEYS[name]
            j = last_open
            if key && j >= 0 && keys[j] == key && stack_top > 0 && stack[stack_top - 1] == j
              # the end tag of the innermost open tag
              inner_ends[j] = tag_start - 2
              ends[j] = p
              stack_top -= 1
              open_p -= 1 if key == P
              open_in_list[key] -= 1
              last_open = prev_open[j]
              i = p + 1
              next
            end
          end
        else
          l = c | 0x20
          unless (l >= 97 && l <= 122) || c == 33 || c == 63
            i += 1
            next
          end
          if c != 33
            name = ss.scan(NAME_PART)
            p = ss.pos
            p += ss.skip(TAG_BODY) if src.getbyte(p) != 62
            last = p < to ? src.getbyte(p - 1) : 0
            if name && p < to && src.getbyte(p) == 62 && last < 0x80 && (key = KEYS[name] || (name.bytesize <= 32 && KEYS[name.downcase]))
              # in XML only "?xml" is void here ('!' never takes this path)
              flags = is_xml ? (c == 63 ? F_VOID : 0) : FLAGS[key]
              if flags & F_RULE == 0 || stack_top == 0 || (top = keys[stack[stack_top - 1]]) < 0 || !RULES[key].t[top]
                if open_p == 0 || flags & F_CLOSES_P == 0
                  # a known tag that ends no open tag
                  if stack_top > 0
                    parent = stack[stack_top - 1]
                    depth = depths[parent] + 1
                  else
                    parent = -1
                    depth = 0
                  end
                  customs[count] = empty
                  parents[count] = parent
                  starts[count] = i
                  ends[count] = p
                  inner_starts[count] = p + 1
                  inner_ends[count] = 0
                  keys[count] = key
                  depths[count] = depth
                  if flags & F_VOID != 0
                    prev_open[count] = -1
                    self_closed[count] = false
                    count += 1
                    i = p + 1
                    next
                  end
                  self_closing = last == 47 || (last <= 32 && self_closing?(tag_start, p))
                  self_closed[count] = self_closing
                  prev_open[count] = last_open
                  last_open = count
                  open_in_list[key] += 1
                  count += 1
                  i = p + 1
                  next if self_closing

                  if stack_top < MAX_DEPTH
                    stack[stack_top] = count - 1
                    stack_top += 1
                    open_p += 1 if key == P
                  end
                  # <script>, <style>, ...: continue right before the matching end tag
                  i = Parser.find_raw_text_end(src, p + 1, RAW_TEXT_ENDS[key], to) if flags & F_RAW_TEXT != 0
                  next
                end
              end
            end
          end
        end
        # anything else: the general code, with the state written back
        @count = count
        @stack_top = stack_top
        @last_open = last_open
        @open_p = open_p
        stop = scan_one(i, to)
        count = @count
        stack_top = @stack_top
        last_open = @last_open
        open_p = @open_p
        if stop < 0
          @tag_started = true
          @tag_start = i + 1
          return
        end
        i = stop
      end
      @count = count
      @stack_top = stack_top
      @last_open = last_open
      @open_p = open_p
      @tag_started = false
    end

    # Parses src[from, to) (from is outside a tag), adding tags at count. Tags still open at to stay on the stack.
    # Every String method call costs about as much as twenty plain operations, so the common cases are read with as
    # few of them as possible: the name of a start tag and the rest of the tag by two regexps, the name of an end tag
    # looked up untrimmed (a name with spaces around it is not a tag name and takes the slow way).
    def scan(rules, from, to)
      src = @src
      ss = @ss
      tag_started = false
      tag_start = 0
      i = from
      while i < to
        # Outside a tag only '<' matters: jump to it.
        lt = src.index(LT, i)
        break if lt.nil? || lt >= to

        i = lt
        break if i + 1 >= to

        c = src.getbyte(i + 1)
        tag_start = i + 1
        if c == 47
          # an end tag; inside a tag only '<', '=' and '>' matter
          ss.pos = tag_start
          p = tag_start + ss.skip(TAG_BODY)
          p = scan_tag_slowly(tag_start, to) if p >= to
          if p < 0
            tag_started = true
            break
          end
          if src.getbyte(p) == 60
            # An unfinished tag: start over at this '<' (it may also start a comment).
            i = p
            next
          end
          end_tag(rules, tag_start, p)
          i = p + 1
          next
        end

        # As in HTML5, '<' starts markup only before a letter, '/', '!' or '?': "a < b" is text.
        l = c | 0x20
        unless (l >= 97 && l <= 122) || c == 33 || c == 63
          i += 1
          next
        end
        if c == 33 && i + 4 <= to && src.getbyte(i + 2) == 45 && src.getbyte(i + 3) == 45
          # <!-- ... -->: one "!--" tag; its content is not markup, it does not nest anything.
          i = comment(i, to) + 1
          next
        end

        ss.pos = tag_start
        # nil when the name runs into '=': then the name is read byte by byte
        name = ss.scan(NAME_PART)
        p = ss.pos
        # a tag without attributes ends right after its name
        p += ss.skip(TAG_BODY) if src.getbyte(p) != 62
        p = scan_tag_slowly(tag_start, to) if p >= to
        if p < 0
          tag_started = true
          break
        end
        if src.getbyte(p) == 60
          i = p
          next
        end
        i = start_tag(rules, tag_start, p, to, c, name) + 1
      end
      @tag_started = tag_started
      @tag_start = tag_start
    end

    private

    # One step of scan(false, ...) at the '<' at i: the position to go on from, or -1 for a tag that does not end.
    def scan_one(i, to)
      src = @src
      ss = @ss
      c = src.getbyte(i + 1)
      tag_start = i + 1
      ss.pos = tag_start
      if c == 47
        p = tag_start + ss.skip(TAG_BODY)
        p = scan_tag_slowly(tag_start, to) if p >= to
        return -1 if p < 0
        return p if src.getbyte(p) == 60

        end_tag(false, tag_start, p)
        return p + 1
      end
      l = c | 0x20
      return i + 1 unless (l >= 97 && l <= 122) || c == 33 || c == 63
      return comment(i, to) + 1 if c == 33 && i + 4 <= to && src.getbyte(i + 2) == 45 && src.getbyte(i + 3) == 45

      name = ss.scan(NAME_PART)
      p = ss.pos
      p += ss.skip(TAG_BODY) if src.getbyte(p) != 62
      p = scan_tag_slowly(tag_start, to) if p >= to
      return -1 if p < 0
      return p if src.getbyte(p) == 60

      start_tag(false, tag_start, p, to, c, name) + 1
    end

    # Whether the opening tag that ends at gt (with whitespace before '>') ends with "/".
    def self_closing?(tag_start, gt)
      src = @src
      e = gt
      e -= 1 while e > tag_start && Chars.space_byte?(src.getbyte(e - 1))
      e > tag_start && src.getbyte(e - 1) == 47
    end

    # The inside of a tag from i, as the fast scan reads it but within to: the position of the '<' or '>' that ends
    # it, or -1 when the tag does not end before to.
    def scan_tag_slowly(i, to)
      src = @src
      while i < to
        c = src.getbyte(i)
        return i if c == 60 || c == 62

        if c == 61
          q = i + 1
          q += 1 while q < to && Chars.space_byte?(src.getbyte(q))
          if q < to
            quote = src.getbyte(q)
            if quote == 34 || quote == 39
              close = src.index(quote == 34 ? '"' : "'", q + 1)
              i = close if close && close < to
            end
          end
        end
        i += 1
      end
      -1
    end

    # Adds the comment that starts at i; returns the position of its '>'.
    def comment(i, to)
      comment_end = Parser.find_comment_end(@src, i + 4, to)
      parent = -1
      depth = 0
      if @stack_top > 0
        parent = @stack[@stack_top - 1]
        depth = @depth[parent] + 1
      end
      k = @count
      @key[k] = COMMENT
      @customs[k] = Chars::EMPTY
      @parents[k] = parent
      @starts[k] = i
      @ends[k] = comment_end
      @inner_starts[k] = comment_end + 1
      @inner_ends[k] = 0
      @depth[k] = depth
      @prev_open[k] = -1
      @self_closed[k] = false
      @count = k + 1
      comment_end
    end

    # Matches the end tag src[tag_start-1 .. gt] to the innermost open tag with that name.
    def end_tag(rules, tag_start, gt)
      src = @src
      from = tag_start + 1
      to = gt
      # Nearly always the name as it stands is a known tag name.
      name = src.byteslice(from, to - from)
      key = KEYS[name]
      unless key
        if from < to && ((b = src.getbyte(to - 1)) <= 32 || b >= 0x80)
          while (n = Chars.space_before(src, to, from)) > 0
            to -= n
          end
        end
        if from < to && ((b = src.getbyte(from)) <= 32 || b >= 0x80)
          while (n = Chars.space_at(src, from, to)) > 0
            from += n
          end
        end
        return if from == to

        # Resolve the name once, then compare ints instead of a lookup per candidate.
        name = src.byteslice(from, to - from)
        key = KEYS[name] || (to - from <= 32 && KEYS[name.downcase]) || -1
      end

      # Well-formed markup: the end tag closes the innermost open tag, which is on top of the stack. What match_end
      # and truncate_open_list do for it, without the loops.
      j = @last_open
      if key >= 0 && j >= 0 && @key[j] == key && @stack_top > 0 && @stack[@stack_top - 1] == j
        @inner_ends[j] = tag_start - 2
        @ends[j] = gt
        @stack_top -= 1
        @open_p -= 1 if key == P
        @open_by_key[key] -= 1 if rules
        @open_in_list[key] -= 1
        @last_open = @prev_open[j]
        return
      end
      # The rules may have ended the matched tag itself (<li><div><li>x</div>: the second <li> ends the first one
      # together with its <div>, as in a browser): the end tag is matched again, to what is open now.
      # Once: the part is not scanned a second time.
      return unless match_end(rules, key, name, tag_start, gt, true)

      match_end(rules, key, name, tag_start, gt, false)
    end

    # Ends the innermost open tag with the end tag's name. Returns true when it scanned a part again with the
    # optional-end-tag rules instead, and the end tag is to be matched once more.
    def match_end(rules, key, name, tag_start, gt, can_repair)
      # A name that no open tag has is a stray end tag: it is skipped without scanning the open tags.
      closing = nil
      if key >= 0
        return false if @open_in_list[key] <= 0
      else
        return false if @custom_open.empty?

        closing = Chars.lower(name)
        return false if (@custom_open[closing] || 0) <= 0
      end

      j = @last_open
      while j >= 0
        if key >= 0
          if @key[j] != key
            j = @prev_open[j]
            next
          end
        elsif @key[j] >= 0 || @customs[j] != closing
          j = @prev_open[j]
          next
        end

        inner_end = tag_start - 2

        # Tags left open inside it: if the optional-end-tag rules apply to one of them,
        # scan its part again with the rules (fast mode only; rules mode has applied them).
        if can_repair && !rules && !@is_xml && @stack_top > 0 && @stack[@stack_top - 1] > j
          above = @stack_top - 1
          above -= 1 while above > 0 && @stack[above - 1] > j
          target = first_misnested(above, @stack_top)
          if target >= 0
            repair(target, tag_start - 1)
            return true
          end
        end

        @inner_ends[j] = inner_end
        @ends[j] = gt

        while @stack_top > 0 && @stack[@stack_top - 1] >= j
          @stack_top -= 1
          popped = @key[@stack[@stack_top]]
          @open_p -= 1 if popped == P
          @open_by_key[popped] -= 1 if rules && popped >= 0
        end

        # It leaves the open list with everything opened after it; the tags opened inside it and
        # never closed end right before this end tag, as in a browser.
        truncate_open_list(j, inner_end)
        return false
      end
      false
    end

    # Adds the tag src[tag_start-1 .. gt]; returns the position to continue from (gt, or before a raw-text end tag).
    # name: the name as the scan read it, nil when it runs into '='.
    def start_tag(rules, tag_start, gt, to, first, name)
      src = @src
      # The name in the inside of the opening tag (trimmed; "!--" for a comment). It starts at tag_start: the first
      # char (first) is a letter, '!' or '?'.
      last = src.getbyte(gt - 1)
      if last >= 0x80 || first == 33 || name.nil?
        end_ = gt
        if last >= 0x80
          while (n = Chars.space_before(src, end_, tag_start)) > 0
            end_ -= n
          end
        end
        if first == 33 && tag_start + 3 <= end_ && src.getbyte(tag_start + 1) == 45 && src.getbyte(tag_start + 2) == 45
          length = 3
        elsif name.nil?
          # The name ends at whitespace or '/': <br/> is "br", as <br /> is.
          e = tag_start
          e += 1 while e < end_ && !Chars.space_byte?(b = src.getbyte(e)) && b != 47
          length = e - tag_start
        else
          length = name.bytesize
          length = end_ - tag_start if tag_start + length > end_
        end
        name = src.byteslice(tag_start, length)
      else
        length = name.bytesize
      end
      key = -1
      custom_name = Chars::EMPTY
      if length > 0
        key = KEYS[name] || (length <= 32 && KEYS[name.downcase]) || -1
        if key < 0
          # Custom names (svg elements, web components, ...): the lower-case name.
          custom_name = Chars.lower(name).freeze
          @custom_open[custom_name] ||= 0
        end
      end
      flags = key >= 0 && !@is_xml ? FLAGS[key] : 0

      if flags != 0
        # Optional end tags (HTML5): <li> ends an open <li>, <td> an open <td>, ...
        if flags & F_RULE != 0
          rule = RULES[key]
          if rules
            # a target is open (in well-formed markup it is not)
            close_in_scope(rule, tag_start - 2, true) if rule.k.any? { |t| @open_by_key[t] > 0 }
          elsif @stack_top > 0
            # The common case of a left-out end tag is caught right here: the innermost open tag is a target.
            top = @key[@stack[@stack_top - 1]]
            apply_rule_in_fast_mode(rule, tag_start) if top >= 0 && rule.t[top]
          end
        end

        # A block element ends an open <p>. Usually no <p> is open and this is one compare.
        if @open_p > 0 && flags & F_CLOSES_P != 0
          if rules
            close_in_scope(P_RULE, tag_start - 2, true)
          else
            apply_rule_in_fast_mode(P_RULE, tag_start)
          end
        end
      end

      # the innermost open tag is the parent
      parent = -1
      depth = 0
      if @stack_top > 0
        parent = @stack[@stack_top - 1]
        depth = @depth[parent] + 1
      end

      index = @count
      @customs[index] = custom_name
      @parents[index] = parent
      @starts[index] = tag_start - 1
      @ends[index] = gt
      @inner_starts[index] = gt + 1
      @inner_ends[index] = 0

      # Void elements (<br>, <img>, <meta>, ...) never contain anything. Neither does markup named "!..." or "?..."
      # (<!doctype>, <?xml ...?>, <?php ...?>, <![if IE]>), in HTML and in XML alike: a bogus comment in a browser,
      # a declaration or processing instruction in XML. first is a letter, '!' or '?' (63), and '!' and '?' sort
      # before the letters: one compare.
      is_void = first <= 63 || flags & F_VOID != 0
      self_closing = is_void
      unless self_closing
        if last == 47
          self_closing = true
        elsif last <= 32
          e = gt
          e -= 1 while e > tag_start && Chars.space_byte?(src.getbyte(e - 1))
          self_closing = e > tag_start && src.getbyte(e - 1) == 47
        end
      end

      @key[index] = key
      @depth[index] = depth
      @self_closed[index] = self_closing && !is_void
      if is_void
        @prev_open[index] = -1
      else
        @prev_open[index] = @last_open
        @last_open = index
        if key >= 0
          @open_in_list[key] += 1
        elsif !custom_name.empty?
          @custom_open[custom_name] += 1
        end
      end
      @count = index + 1

      unless self_closing
        # Deeper than MAX_DEPTH the tag is not nested: it stays in the open list for its end tag.
        if @stack_top < MAX_DEPTH
          @stack[@stack_top] = index
          @stack_top += 1
          @open_p += 1 if key == P
          @open_by_key[key] += 1 if rules && key >= 0
        end

        # <script>, <style>, <textarea>, <title>, ...: the content is text, not markup;
        # continue right before the matching end tag.
        return Parser.find_raw_text_end(src, gt + 1, RAW_TEXT_ENDS[key], to) - 1 if flags & F_RAW_TEXT != 0
      end
      gt
    end

    # ----- implied end tags -----

    # Among the tags left open at stack positions [from, to), the outermost one that a rule should have ended, or -1.
    def first_misnested(from, to)
      s = from
      while s < to - 1
        key = @key[@stack[s]]
        if key >= 0 && IS_RULE_TARGET[key]
          inner = s + 1
          while inner < to
            inner_key = @key[@stack[inner]]
            return s if inner_key >= 0 && RULES[inner_key]&.t&.[](key)

            inner += 1
          end
        end
        s += 1
      end
      -1
    end

    # Scans again with the optional-end-tag rules from the tag at stack position stack_pos up to region_end:
    # the tags from it on are replaced, the ones before it are kept.
    def repair(stack_pos, region_end)
      first = @stack[stack_pos]
      from = @starts[first]

      # Past the budget the part is left as it is, so that parsing stays linear on any markup.
      cost = region_end - from
      return if cost > @budget

      @budget -= cost

      truncate_open_list(first, -1)
      @stack_top = stack_pos
      @count = first

      @open_by_key.fill(0)
      @open_p = 0
      s = 0
      while s < stack_pos
        key = @key[@stack[s]]
        if key >= 0
          @open_by_key[key] += 1
          @open_p += 1 if key == P
        end
        s += 1
      end

      scan(true, from, region_end)
    end

    # Removes the tags from index first on from the open list (they are its tail).
    # With end_ >= 0 the ones that have no end tag of their own end there.
    def truncate_open_list(first, end_)
      k = @last_open
      while k >= first
        key = @key[k]
        if key >= 0
          @open_in_list[key] -= 1
        else
          custom = @customs[k]
          @custom_open[custom] -= 1 if !custom.empty? && @custom_open.key?(custom)
        end

        if end_ >= 0 && !@self_closed[k] && @inner_ends[k] == 0
          @inner_ends[k] = end_
          @ends[k] = end_
        end
        k = @prev_open[k]
      end
      @last_open = k
    end

    # The stack position of the outermost target of the rule below the first stop tag, or -1.
    def scope_start(rule)
      from = -1
      s = @stack_top - 1
      while s >= 0
        k = @key[@stack[s]]
        if k >= 0
          if rule.t[k]
            from = s
          elsif rule.s[k]
            break
          end
        end
        s -= 1
      end
      from
    end

    # Applies the rule for the tag that starts at tag_start. If a tag it ends was itself misnested,
    # that part is scanned again with the rules first.
    def apply_rule_in_fast_mode(rule, tag_start)
      from = scope_start(rule)
      return if from < 0

      m = first_misnested(from, @stack_top)
      if m >= 0
        repair(m, tag_start - 1)
        from = scope_start(rule) # the part scanned again changed the stack
      end
      close_from(from, tag_start - 2, false)
    end

    # Ends the outermost target found below the first stop tag together with everything opened inside it.
    def close_in_scope(rule, end_, by_key)
      close_from(scope_start(rule), end_, by_key)
    end

    # Ends the tag at stack position from (-1: none) together with everything opened inside it.
    def close_from(from, end_, by_key)
      return if from < 0

      first = @stack[from]
      while @stack_top > from
        @stack_top -= 1
        key = @key[@stack[@stack_top]]
        @open_p -= 1 if key == P
        @open_by_key[key] -= 1 if by_key && key >= 0
      end
      truncate_open_list(first, end_)
    end
  end
end
