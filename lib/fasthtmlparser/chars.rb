# frozen_string_literal: true

module FastHtmlParser
  # @api private Character helpers shared by the parser, the text readers and the query engines. Inside the library
  # every string is binary (ASCII-8BIT) UTF-8 bytes and positions are byte offsets; strings given by the caller are
  # made binary with Chars.b, and strings given back are UTF-8 (Chars.u).
  module Chars
    BINARY = Encoding::BINARY
    UTF_8 = Encoding::UTF_8
    EMPTY = "".b.freeze
    REPLACEMENT = "\xEF\xBF\xBD".b.freeze # U+FFFD

    # ASCII whitespace as the parser sees it: space, \t, \n, \v, \f, \r.
    SPACE = " \t\n\v\f\r"

    # One whitespace char as .NET char.IsWhiteSpace sees it, in UTF-8 bytes: ASCII, U+0085, U+00A0, U+1680,
    # U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.
    UNICODE_SPACE = "(?:[\\t-\\r ]|\\xC2[\\x85\\xA0]|\\xE1\\x9A\\x80|\\xE2\\x80[\\x80-\\x8A\\xA8\\xA9\\xAF]|" \
                    "\\xE2\\x81\\x9F|\\xE3\\x80\\x80)"
    SPACE_RUNS = Regexp.new("#{UNICODE_SPACE}+".b, Regexp::NOENCODING)
    # the first bytes of every whitespace char
    SPACE_BYTE = /[\t-\r \xC2\xE1-\xE3]/n
    CONTINUATION_BYTES = "\x80-\xBF".b.freeze
    FOUR_BYTE_LEADS = "\xF0-\xF7".b.freeze

    module_function

    # A string given by the caller, as the library works with it: ASCII-only strings are used as they are (they
    # compare and hash the same in any encoding), others as binary.
    def b(s)
      s = s.to_s unless s.is_a?(String)
      s.ascii_only? ? s : s.b
    end

    # A string given back to the caller: UTF-8. The string must not be one the library keeps (those are frozen).
    def u(s)
      return s if s.encoding == UTF_8

      s = s.dup if s.frozen?
      s.force_encoding(UTF_8)
    end

    def space_byte?(c)
      c == 32 || (c && c >= 9 && c <= 13)
    end

    # The byte length of the whitespace char (char.IsWhiteSpace) that starts at i, or 0.
    def space_at(s, i, limit)
      return 0 if i >= limit

      c = s.getbyte(i)
      return c == 32 || (c >= 9 && c <= 13) ? 1 : 0 if c < 0x80

      if c == 0xc2
        return 0 if i + 1 >= limit

        d = s.getbyte(i + 1)
        return d == 0x85 || d == 0xa0 ? 2 : 0
      end
      return 0 if c < 0xe1 || c > 0xe3 || i + 2 >= limit

      d = s.getbyte(i + 1)
      e = s.getbyte(i + 2)
      return d == 0x9a && e == 0x80 ? 3 : 0 if c == 0xe1
      return d == 0x80 && e == 0x80 ? 3 : 0 if c == 0xe3
      return (e >= 0x80 && e <= 0x8a) || e == 0xa8 || e == 0xa9 || e == 0xaf ? 3 : 0 if d == 0x80

      d == 0x81 && e == 0x9f ? 3 : 0
    end

    # The byte length of the whitespace char (char.IsWhiteSpace) that ends right before end_ (not before from), or 0.
    def space_before(s, end_, from)
      return 0 if end_ <= from

      c = s.getbyte(end_ - 1)
      return c == 32 || (c >= 9 && c <= 13) ? 1 : 0 if c < 0x80
      return 0 if c > 0xbf
      return c == 0x85 || c == 0xa0 ? 2 : 0 if end_ - 2 >= from && s.getbyte(end_ - 2) == 0xc2
      return space_at(s, end_ - 3, end_) == 3 ? 3 : 0 if end_ - 3 >= from

      0
    end

    # s[from, to) trimmed of Unicode whitespace (char.IsWhiteSpace), as a new string.
    def trim_range(s, from, to)
      len = s.bytesize
      to = len if to > len
      from = 0 if from < 0
      while from < to
        c = s.getbyte(from)
        if c < 0x80
          break unless c == 32 || (c >= 9 && c <= 13)

          from += 1
        else
          n = space_at(s, from, to)
          break if n == 0

          from += n
        end
      end
      while to > from
        c = s.getbyte(to - 1)
        if c < 0x80
          break unless c == 32 || (c >= 9 && c <= 13)

          to -= 1
        else
          n = space_before(s, to, from)
          break if n == 0

          to -= n
        end
      end
      from >= to ? +"".b : s.byteslice(from, to - from)
    end

    # Trims Unicode whitespace (char.IsWhiteSpace) from both ends.
    def trim_space(s)
      return s if s.empty?

      first = s.getbyte(0)
      last = s.getbyte(-1)
      if first > 32 && first < 0xc2 && last > 32 && last < 0x80
        s
      else
        trim_range(s, 0, s.bytesize)
      end
    end

    # Trims ASCII whitespace from the end.
    def trim_right_ascii(s)
      e = s.bytesize
      e -= 1 while e > 0 && space_byte?(s.getbyte(e - 1))
      e == s.bytesize ? s : s.byteslice(0, e)
    end

    # Lower case: ASCII, and Unicode for valid UTF-8.
    def lower(s)
      return s.downcase if s.ascii_only?

      t = s.dup.force_encoding(UTF_8)
      t.valid_encoding? ? t.downcase!&.b || t.b : s.downcase
    end

    # Upper case: ASCII, and Unicode for valid UTF-8.
    def upper(s)
      return s.upcase if s.ascii_only?

      t = s.dup.force_encoding(UTF_8)
      t.valid_encoding? ? t.upcase!&.b || t.b : s.upcase
    end

    def ascii_lower(s)
      s.downcase(:ascii)
    end

    def ascii?(s)
      s.ascii_only?
    end

    # Case-insensitive comparison (ASCII fast path, Unicode lower case otherwise).
    def equal_fold(a, b)
      return true if a == b

      return a.bytesize == b.bytesize && a.casecmp?(b) if a.ascii_only? && b.ascii_only?
      return false if utf16_length(a) != utf16_length(b)

      lower(a) == lower(b)
    end

    # Whether s[at..] starts with the ASCII string sub, ignoring ASCII case.
    def starts_with_fold?(s, at, sub)
      n = sub.bytesize
      return false if at < 0 || at + n > s.bytesize

      n == 0 || s.byteslice(at, n).casecmp?(sub)
    end

    # Case-insensitive (ASCII) search for sub in s[from, to); -1 when it is not there.
    def index_fold(s, sub, from, to)
      n = sub.bytesize
      return from if n == 0
      return -1 if from + n > to

      i = s.downcase.index(sub.downcase, from)
      i.nil? || i + n > to ? -1 : i
    end

    def hex_byte?(c)
      c && ((c >= 48 && c <= 57) || ((c | 0x20) >= 97 && (c | 0x20) <= 102))
    end

    def alpha_byte?(c)
      c && (c | 0x20) >= 97 && (c | 0x20) <= 122
    end

    def digit_byte?(c)
      c && c >= 48 && c <= 57
    end

    # s[from, to) clamped to the string, "" when from >= to.
    def slice(s, from, to)
      len = s.bytesize
      to = len if to > len
      from = 0 if from < 0
      from >= to ? +"".b : s.byteslice(from, to - from)
    end

    # The length in UTF-16 code units, as .NET counts.
    def utf16_length(s)
      n = s.bytesize
      return n if s.ascii_only?

      n - s.count(CONTINUATION_BYTES) + s.count(FOUR_BYTE_LEADS)
    end

    # The UTF-8 encoding of a code point, as binary.
    def utf8(cp)
      return cp.chr if cp < 0x80

      [cp].pack("U").force_encoding(BINARY)
    end

    # The chars of a string (one UTF-8 sequence each; a byte of invalid UTF-8 is a char of its own), as binary strings.
    def chars(s)
      return s.chars if s.ascii_only?

      s.dup.force_encoding(UTF_8).each_char.map { |c| c.force_encoding(BINARY) }
    end

    # The code point of one UTF-8 char.
    def code_point(ch)
      c = ch.getbyte(0)
      n = ch.bytesize
      return c if c < 0x80 || n == 1
      return ((c & 0x1f) << 6) | (ch.getbyte(1) & 0x3f) if c < 0xe0
      return ((c & 0x0f) << 12) | ((ch.getbyte(1) & 0x3f) << 6) | (ch.getbyte(2) & 0x3f) if c < 0xf0

      ((c & 0x07) << 18) | ((ch.getbyte(1) & 0x3f) << 12) | ((ch.getbyte(2) & 0x3f) << 6) | (ch.getbyte(3) & 0x3f)
    end

    # The string as valid UTF-8: invalid sequences become U+FFFD.
    def scrub(s)
      return s if s.ascii_only?

      t = s.dup.force_encoding(UTF_8)
      t.valid_encoding? ? s : t.scrub("\uFFFD").force_encoding(BINARY)
    end

    # A string in double quotes, for error messages.
    def quote(s)
      t = s.dup.force_encoding(UTF_8)
      t = t.scrub("\uFFFD") unless t.valid_encoding?
      "\"#{t.gsub(/["\\]/) { "\\#{::Regexp.last_match(0)}" }}\""
    end
  end
end
