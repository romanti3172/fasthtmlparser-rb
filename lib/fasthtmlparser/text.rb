# frozen_string_literal: true

module FastHtmlParser
  # @api private Visible text: tags, comments and invisible content removed, whitespace collapsed, entities decoded.
  module Text
    SPACE_RUNS = Chars::SPACE_RUNS
    SPACE_BYTE = Chars::SPACE_BYTE
    INVISIBLE = {
      "style" => "</style", "script" => "</script", "noembed" => "</noembed", "noscript" => "</noscript",
      "template" => "</template", "noframes" => "</noframes"
    }.freeze
    LT = "<"
    GT = ">"
    SP = " "

    module_function

    # s[i] is '<'. Returns the index of the last char of what is not text there: a comment, a tag, or a tag together
    # with invisible content (script, style, ...) up to its end tag. -1: an unterminated tag.
    def skip_markup(s, i)
      n = s.bytesize
      if i + 4 <= n && s.getbyte(i + 1) == 33 && s.getbyte(i + 2) == 45 && s.getbyte(i + 3) == 45
        return Parser.find_comment_end(s, i + 4, n)
      end

      tag_end = s.index(GT, i + 1)
      return -1 if tag_end.nil?

      end_tag = invisible_content_end(s, i + 1, tag_end)
      return Parser.find_raw_text_end(s, tag_end + 1, end_tag, n) - 1 if end_tag

      tag_end
    end

    # For the inside of an opening tag s[from, to), the end tag ("</script") when the element's content is never
    # visible text (script, style, noscript, template, noframes, noembed), otherwise nil.
    def invisible_content_end(s, from, to)
      return nil if from >= to

      first = s.getbyte(from) | 0x20
      return nil if first != 0x73 && first != 0x74 && first != 0x6e # s, t, n

      n = 1
      while from + n < to && n <= 8
        c = s.getbyte(from + n) | 0x20
        break if c < 0x61 || c > 0x7a

        n += 1
      end
      if from + n < to
        c = s.getbyte(from + n)
        return nil if c != 47 && !Chars.space_byte?(c)
      end
      end_ = INVISIBLE[s.byteslice(from, n).downcase(:ascii)]
      return nil if end_.nil?

      e = to
      e -= 1 while e > from && Chars.space_byte?(s.getbyte(e - 1))
      return nil if s.getbyte(e - 1) == 47 # <script src="x" />: no content

      end_
    end

    # The text runs of s with tags, comments and invisible content removed, whitespace not yet collapsed.
    def text_runs(s)
      lt = s.index(LT)
      return s if lt.nil?

      n = s.bytesize
      out = String.new(capacity: n, encoding: Encoding::BINARY)
      from = 0
      while lt
        unless Parser.markup_start?(s, lt, n)
          lt = s.index(LT, lt + 1)
          next
        end
        out << s.byteslice(from, lt - from) if lt > from
        last = skip_markup(s, lt)
        return out if last < 0 # an unterminated tag: the rest is markup

        from = last + 1
        lt = s.index(LT, from)
      end
      return s if from == 0

      out << s.byteslice(from, n - from) if from < n
      out
    end

    # Whitespace runs as one ' ', trimmed.
    def collapse(s)
      return s unless SPACE_BYTE.match?(s)

      t = s.gsub(SPACE_RUNS, SP)
      return t if t.empty?

      a = t.getbyte(0) == 32 ? 1 : 0
      z = t.bytesize - (t.getbyte(-1) == 32 ? 1 : 0)
      a == 0 && z == t.bytesize ? t : Chars.slice(t, a, z)
    end

    # The visible text of an HTML fragment.
    def clear_tags(s)
      return +"".b if s.empty?

      text = collapse(text_runs(s))
      text.include?(Decode::AMP) ? Decode.decode(text, false) : text
    end

    # Whether the visible text of the body (value) equals expected; n gives the full text.
    def text?(value, expected, n)
      return false if value.empty? || expected.empty?

      # whitespace is collapsed even where text keeps it (a tag without children), as the .NET version compares
      text = collapse(text_runs(value))
      amp = text.index(Decode::AMP)
      return text == expected if amp.nil?

      # Text with entities must be decoded before comparing: the full text, when the part before it matches.
      head = text.byteslice(0, amp)
      head = head.byteslice(0, head.bytesize - 1) while head.end_with?(SP)
      expected.start_with?(head) && n.text_bytes == expected
    end
  end

  # @api private Text with the visible line structure kept (HtmlNode#text_line_breaks).
  class TextLines
    BREAK_SPACE = 1 # table cell: word separator
    BREAK_LINE = 2 # <br> and block elements (div, li, tr, ...): new line
    BREAK_PARAGRAPH = 3 # p, h1-h6: new paragraph (blank line)
    BREAK_SKIP_CONTENT = 4 # script, style, noscript: contents are not text
    # inline tags (b, span, a, ...) are removed, words are not split

    KEYS = TagNames::KEYS
    BR = KEYS["br"]

    KINDS = Array.new(TagNames::NAMES.size, 0)
    %w[p h1 h2 h3 h4 h5 h6].each { |t| KINDS[KEYS[t]] = BREAK_PARAGRAPH }
    %w[br div li ul ol dl dt dd table caption tr thead tbody tfoot section article aside nav header footer main address
       blockquote pre hr figure figcaption form fieldset legend details summary dialog option html head body title
       hgroup search menu center dir listing xmp plaintext multicol frameset marquee].each do |t|
      KINDS[KEYS[t]] = BREAK_LINE
    end
    KINDS[KEYS["td"]] = BREAK_SPACE
    KINDS[KEYS["th"]] = BREAK_SPACE
    %w[script style noscript template noframes noembed].each { |t| KINDS[KEYS[t]] = BREAK_SKIP_CONTENT }
    KINDS.freeze

    SPACE_RUNS = Chars::SPACE_RUNS
    SPACE_BYTE = Chars::SPACE_BYTE
    PLAIN = /[^&<]*+/n
    TAG_NAME_END = %r{[\t\r\n\f /]}n

    attr_reader :out

    def initialize
      @out = String.new(encoding: Encoding::BINARY)
      @pending_breaks = 0 # new lines requested since the last text char
      @pending_space = false
    end

    # Writes text, collapsing whitespace and turning requested breaks into trimmed lines.
    def chars(s)
      unless SPACE_BYTE.match?(s)
        text(s)
        return
      end
      pos = 0
      n = s.bytesize
      while pos < n
        i = s.index(SPACE_RUNS, pos)
        if i.nil?
          text(s.byteslice(pos, n - pos))
          break
        end
        text(s.byteslice(pos, i - pos)) if i > pos
        @pending_space = true
        pos = i + $~[0].bytesize
      end
    end

    def text(s)
      unless @out.empty?
        # nothing before the first text char: leading breaks and spaces are trimmed
        if @pending_breaks > 0
          @out << (@pending_breaks >= 2 ? "\n\n" : "\n") # at most one blank line
        elsif @pending_space
          @out << " "
        end
      end
      @pending_breaks = 0
      @pending_space = false
      @out << s
    end

    def break!(kind, known)
      if kind == BREAK_LINE
        if known == BR
          @pending_breaks += 1 # every <br> counts
        elsif @pending_breaks < 1
          @pending_breaks = 1
        end
      elsif @pending_breaks < 2
        @pending_breaks = 2
      end
    end

    # The text of an HTML fragment with the visible line structure kept. Lines are joined with "\n".
    def self.clear_tags_line_breaks(value)
      return +"".b if value.empty?

      value = Decode.normalize_newlines(value) # values are read as a browser reads the page
      w = new
      n = value.bytesize
      ss = StringScanner.new(value)
      i = 0
      while i < n
        c = value.getbyte(i)

        if c == 38
          # '&': decoded chars go through the same whitespace/text logic (&nbsp; collapses, &lt; is plain text)
          decoded, consumed = Decode.decode_reference(value, i + 1)
          if decoded
            w.chars(decoded)
            i += 1 + consumed
          else
            w.chars(Decode::AMP)
            i += 1
          end
          next
        end

        if c != 60 || !Parser.markup_start?(value, i, n)
          # plain text up to the next '&' or '<'
          ss.pos = i + 1
          ss.skip(PLAIN)
          j = ss.pos
          w.chars(value.byteslice(i, j - i))
          i = j
          next
        end

        if i + 4 <= n && value.getbyte(i + 1) == 33 && value.getbyte(i + 2) == 45 && value.getbyte(i + 3) == 45
          e = value.index("-->", i + 4)
          break if e.nil?

          i = e + 3
          next
        end

        close_tag = value.index(Text::GT, i)
        break if close_tag.nil? # unterminated tag: the rest is markup

        tag = value.byteslice(i + 1, close_tag - i - 1)
        i = close_tag + 1

        closing = tag.getbyte(0) == 47
        name = closing ? tag.byteslice(1, tag.bytesize - 1) : tag
        stop = name.index(TAG_NAME_END)
        name = name.byteslice(0, stop) if stop
        known = Parser.lookup_tag(name)
        next if known < 0 # unknown tag: just removed

        case KINDS[known]
        when BREAK_LINE, BREAK_PARAGRAPH
          w.break!(KINDS[known], known)
        when BREAK_SPACE
          w.chars(Text::SP)
        when BREAK_SKIP_CONTENT
          if !closing && !Chars.trim_right_ascii(tag).end_with?("/")
            # jump to the closing tag; it is removed on the next iteration
            e = Chars.index_fold(value, "</#{TagNames::NAMES[known]}", i, n)
            i = e < 0 ? n : e
          end
        end
      end
      w.out
    end
  end
end
