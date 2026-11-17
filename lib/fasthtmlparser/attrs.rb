# frozen_string_literal: true

module FastHtmlParser
  # @api private Reads the attributes of an opening tag one by one: positions in the source.
  class AttrScanner
    attr_reader :name_start, :name_length, :value_start, :value_length

    # skip '<' and the name; name chars end at whitespace, '/' or '>'
    NAME_END = %r{[^\t-\r />]*+}n
    # between attributes: whitespace and '/'
    GAP = %r{[\t-\r /]*+}n
    # an attribute name ends at whitespace, '=', '/' or '>'
    ATTR_NAME = %r{[^\t-\r =/>]*+}n

    def initialize(node)
      @src = node.doc.source_bytes
      @end = Attrs.open_tag_end(node)
      @ss = StringScanner.new(@src)
      i = node.start + 1
      if i < @end
        @ss.pos = i
        @ss.skip(NAME_END)
        i = @ss.pos
        i = @end if i > @end
      end
      @pos = i
      @name_start = 0
      @name_length = 0
      @value_start = -1 # -1: no value
      @value_length = 0
    end

    # Moves to the next attribute; false at the end of the tag.
    def next?
      s = @src
      e = @end
      ss = @ss
      loop do
        if @pos < e
          ss.pos = @pos
          ss.skip(GAP)
          @pos = ss.pos < e ? ss.pos : e
        end
        return false if @pos >= e

        @name_start = @pos
        ss.pos = @pos
        ss.skip(ATTR_NAME)
        @pos = ss.pos < e ? ss.pos : e
        @name_length = @pos - @name_start
        if @name_length.zero?
          @pos += 1 # a stray '=': skip it
          next
        end
        @value_start, @value_length, @pos = Attrs.read_value(s, @pos, e)
        return true
      end
    end

    def name
      @src.byteslice(@name_start, @name_length)
    end

    def raw_value
      @value_start.negative? ? +"".b : @src.byteslice(@value_start, @value_length)
    end
  end

  # @api private Attributes are read from the source of the opening tag when they are asked for.
  module Attrs
    CLASS = "class"
    ID = "id"
    # starts a name: after whitespace, a quote, '/' or '='
    NAME_BEFORE = Array.new(256, false)
    " \t\n\v\f\r\"'/=".each_byte { |c| NAME_BEFORE[c] = true }
    NAME_BEFORE.freeze
    # ends a name: at whitespace, '=', '/' or '>'
    NAME_AFTER = Array.new(256, false)
    " \t\n\v\f\r=/>".each_byte { |c| NAME_AFTER[c] = true }
    NAME_AFTER.freeze
    NAME_SIZES = TagNames::NAMES.map(&:bytesize).freeze
    DQ = '"'
    SQ = "'"

    module_function

    # The decoded value of the first attribute with the name (lower case); "" when missing or without a value.
    def attr_value(n, name)
      raw = attr_raw(n, name)
      Decode.needs_decoding?(raw) ? Decode.decode(raw, true) : raw
    end

    # Whether one of the space-separated classes equals cls (case-insensitive).
    def has_class?(n, cls)
      return false if cls.empty?

      value = attr_raw(n, CLASS)
      value = Decode.decode(value, true) if Decode.needs_decoding?(value)
      vl = value.bytesize
      cl = cls.bytesize
      return Chars.equal_fold(value, cls) if vl == cl
      return false if cl > vl

      lv = value.downcase(:ascii)
      lc = cls.downcase(:ascii)
      from = 0
      while from <= vl - cl
        i = lv.index(lc, from)
        return false if i.nil?

        after = i + cl
        if (i.zero? || Chars.space_byte?(lv.getbyte(i - 1))) && (after == vl || Chars.space_byte?(lv.getbyte(after)))
          return true
        end

        from = i + 1
      end
      false
    end

    # The raw value of the first attribute with the name (lower case), as a browser reads the tag: quoted or unquoted
    # (href=/p?a=1), "" for an attribute without a value or a missing one.
    def attr_raw(n, attribute)
      # a comment has no attributes, whatever its text looks like
      return +"".b if attribute.empty? || n.key == Parser::COMMENT

      # the opening tag: "<name attributes", without the closing '>', in lower case
      tag = n.lower_tag
      length = tag.bytesize

      # The first place where the name stands as a word of its own. Most tags have none.
      alen = attribute.bytesize
      p = tag.index(attribute, 1)
      while p
        after = p + alen
        break if NAME_BEFORE[tag.getbyte(p - 1)] && (after == length || NAME_AFTER[tag.getbyte(after)])

        p = p + 1 < length ? tag.index(attribute, p + 1) : nil
      end
      return +"".b if p.nil?

      src = n.doc.source_bytes
      start = n.start
      # That word is the attribute unless it is inside the value of another one (title="see id=5", x= id).
      # Nearly always that is ruled out at once, and the value is read in place.
      key = n.key
      if (key >= 0 && p == NAME_SIZES[key] + 2) || name_for_sure?(tag, p)
        q = p + alen
        while q < length && ((c = tag.getbyte(q)) == 32 || (c >= 9 && c <= 13))
          q += 1
        end
        return +"".b if q >= length || tag.getbyte(q) != 61 # no value

        q += 1
        while q < length && ((c = tag.getbyte(q)) == 32 || (c >= 9 && c <= 13))
          q += 1
        end
        return +"".b if q >= length

        if c == 34 || c == 39
          close = tag.index(c == 34 ? DQ : SQ, q + 1)
          return close.nil? ? src.byteslice(start + q + 1, length - q - 1) : src.byteslice(start + q + 1, close - q - 1)
        end
        v = q
        while v < length && !((c = tag.getbyte(v)) == 32 || (c >= 9 && c <= 13))
          v += 1
        end
        return src.byteslice(start + q, v - q)
      end
      pos = start + p

      # Otherwise the attributes are read one by one, up to the one that starts at that word.
      s = AttrScanner.new(n)
      while s.next?
        # a word the scanner has passed was inside a value: the next one takes its place
        while pos < s.name_start
          pos = next_word(tag, start, attribute, pos + 1)
          return +"".b if pos.negative?
        end
        if pos == s.name_start && s.name_length == alen
          return s.value_start.negative? ? +"".b : src.byteslice(s.value_start, s.value_length)
        end
      end
      +"".b
    end

    # The next place in the opening tag (tag, lower case, at start in the source) at or after the source position
    # from where the name stands as a word of its own, or -1.
    def next_word(tag, start, attribute, from)
      n = attribute.bytesize
      length = tag.bytesize
      i = from - start
      while i < length
        found = tag.index(attribute, i)
        break if found.nil?

        after = found + n
        return start + found if NAME_BEFORE[tag.getbyte(found - 1)] && (after == length || NAME_AFTER[tag.getbyte(after)])

        i = found + 1
      end
      -1
    end

    # Whether the word at pos of the opening tag ("<name attributes") is an attribute name, judged by the chars before
    # it alone. False means "not sure".
    def name_for_sure?(tag, pos)
      # After whitespace, and not as the unquoted value in "x= word".
      return false unless Chars.space_byte?(tag.getbyte(pos - 1))

      e = pos
      e -= 1 while e.positive? && Chars.space_byte?(tag.getbyte(e - 1))
      return false if tag.getbyte(e - 1) == 61

      # Not inside a quoted value: it is enough that the last quote of each kind before the word does not open a value.
      ['"', "'"].each do |quote|
        i = tag.rindex(quote, e - 1)
        next if i.nil?

        j = i
        j -= 1 while j.positive? && Chars.space_byte?(tag.getbyte(j - 1))
        return false if j.positive? && tag.getbyte(j - 1) == 61
      end
      true
    end

    # Compares the decoded value; decodes only when the raw value has '&' or CR.
    def attr_equals?(raw, value)
      Decode.needs_decoding?(raw) ? Decode.decode(raw, true) == value : raw == value
    end

    # Whether the decoded value starts with prefix.
    def attr_starts_with?(raw, prefix)
      (Decode.needs_decoding?(raw) ? Decode.decode(raw, true) : raw).start_with?(prefix)
    end

    # The position of the '>' that ends the opening tag.
    def open_tag_end(n)
      end_ = n.inner_start.positive? && n.inner_end.positive? ? n.inner_start - 1 : n.end
      len = n.doc.source_bytes.bytesize
      end_ < len ? end_ : len
    end

    # Reads the value that follows an attribute name at pos (before end_): [value start (-1: no '='), length,
    # the position after the value].
    def read_value(s, pos, end_)
      p = pos
      p += 1 while p < end_ && Chars.space_byte?(s.getbyte(p))
      return [-1, 0, pos] if p >= end_ || s.getbyte(p) != 61

      p += 1
      p += 1 while p < end_ && Chars.space_byte?(s.getbyte(p))
      q = p < end_ ? s.getbyte(p) : nil
      if q == 34 || q == 39
        start = p + 1
        close = start < end_ ? s.index(q == 34 ? '"' : "'", start) : nil
        return [start, end_ - start > 0 ? end_ - start : 0, end_] if close.nil? || close >= end_

        return [start, close - start, close + 1]
      end
      start = p
      p += 1 while p < end_ && !Chars.space_byte?(s.getbyte(p))
      [start, p - start, p]
    end

    # Whether the element has the attribute (lower case), with or without a value.
    def has_attribute?(n, name)
      return true unless attr_raw(n, name).empty?
      return false if n.key == Parser::COMMENT

      s = AttrScanner.new(n)
      while s.next?
        return true if Chars.equal_fold(s.name, name)
      end
      false
    end
  end
end
