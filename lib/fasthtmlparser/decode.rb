# frozen_string_literal: true

module FastHtmlParser
  # @api private HTML5 character reference decoder (WHATWG "character reference state"): all 2125 named references,
  # the legacy names without ';', numeric references with or without ';', and the spec replacements (0, surrogates,
  # > U+10FFFF -> U+FFFD; 0x80-0x9F -> Windows-1252).
  module Decode
    # Replacements for numeric references 0x80..0x9F; 0 = keep the code point as is.
    WINDOWS_1252 = [
      0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0,
      0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e,
      0x0178
    ].freeze

    MAP = Entities::MAP
    LEGACY = Entities::LEGACY
    MAX_NAME = Entities::MAX_NAME
    MAX_LEGACY_NAME = Entities::MAX_LEGACY_NAME
    AMP = "&"
    CR = "\r"
    NEEDS_DECODING = /[&\r]/n
    ALNUM_RUN = /[0-9A-Za-z]{0,#{MAX_NAME + 1}}/n

    module_function

    def alnum?(c)
      c && ((c >= 48 && c <= 57) || ((c | 0x20) >= 97 && (c | 0x20) <= 122))
    end

    # Whether a value read from the page differs from its source: it has a character reference or a CR.
    def needs_decoding?(s)
      s.include?(AMP) || s.include?(CR)
    end

    # HTML input stream preprocessing: CR LF and a lone CR become LF.
    def normalize_newlines(s)
      return s unless s.include?(CR)

      s.gsub("\r\n", "\n").tr("\r", "\n")
    end

    # Decodes the character references in s; CR LF and a lone CR become LF. With in_attribute, a legacy name without
    # ';' followed by '=' or an alphanumeric is left as is (so "?a=1&copy=2" stays intact). Returns a new string or s.
    def decode(s, in_attribute)
      # Line breaks first, as a browser reads the page; a CR written as "&#13;" is decoded after that and stays.
      s = normalize_newlines(s) if s.include?(CR)
      amp = s.index(AMP)
      return s if amp.nil?

      n = s.bytesize
      out = String.new(capacity: n, encoding: Encoding::BINARY)
      pos = 0
      while amp
        out << s.byteslice(pos, amp - pos) if amp > pos
        consumed = 0
        text = nil
        if amp + 1 < n
          text, consumed = reference(s, amp + 1, in_attribute)
        end
        if text.nil?
          out << AMP # not a reference: keep '&'
          pos = amp + 1
        else
          out << text
          pos = amp + 1 + consumed
        end
        amp = pos < n ? s.index(AMP, pos) : nil
      end
      out << s.byteslice(pos, n - pos) if pos < n
      out
    end

    # Decodes one character reference; s[at] is the char right after '&'. Returns [text, bytes consumed after '&'],
    # or [nil, 0] when there is no reference.
    def decode_reference(s, at)
      return [nil, 0] if at >= s.bytesize

      reference(s, at, false)
    end

    def reference(s, at, in_attribute)
      if s.getbyte(at) == 35
        cp, consumed = match_numeric(s, at)
        return [nil, 0] if cp.negative?

        return [Chars.utf8(cp), consumed]
      end
      match_named(s, at, in_attribute)
    end

    # s[at] is '#'. Returns [code point (-1: not a reference), bytes consumed].
    def match_numeric(s, at)
      n = s.bytesize
      i = at + 1
      c = i < n ? s.getbyte(i) : nil
      hex = c == 120 || c == 88
      i += 1 if hex
      digits = i
      value = 0
      if hex
        while i < n
          c = s.getbyte(i)
          if c >= 48 && c <= 57
            d = c - 48
          else
            l = c | 0x20
            break if l < 97 || l > 102

            d = l - 87
          end
          value = value * 16 + d
          value = 0x110000 if value > 0x10ffff # saturate on long digit runs
          i += 1
        end
      else
        while i < n
          c = s.getbyte(i)
          break if c < 48 || c > 57

          value = value * 10 + c - 48
          value = 0x110000 if value > 0x10ffff
          i += 1
        end
      end
      return [-1, 0] if i == digits # "&#" / "&#x" without digits is plain text

      i += 1 if i < n && s.getbyte(i) == 59
      if value.zero? || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)
        value = 0xfffd
      elsif value >= 0x80 && value <= 0x9f
        mapped = WINDOWS_1252[value - 0x80]
        value = mapped if mapped != 0
      end
      [value, i - at]
    end

    # s[at] is the char right after '&'. Returns [decoded text (nil: not a reference), bytes consumed].
    def match_named(s, at, in_attribute)
      len = s.bytesize
      n = 0
      limit = MAX_NAME + 1
      n += 1 while n < limit && at + n < len && alnum?(s.getbyte(at + n))
      return [nil, 0] if n < 2

      # Full match: "&name;".
      if at + n < len && s.getbyte(at + n) == 59
        v = MAP[s.byteslice(at, n)]
        return [v, n + 1] if v
      end
      # Longest legacy prefix without ';': "&copy2024" -> "(c)2024", "&notit;" -> "(not)it;".
      k = n < MAX_LEGACY_NAME ? n : MAX_LEGACY_NAME
      while k >= 2
        name = s.byteslice(at, k)
        if LEGACY[name]
          if in_attribute && at + k < len
            c = s.getbyte(at + k)
            break if c == 61 || alnum?(c)
          end
          return [MAP[name], k]
        end
        k -= 1
      end
      [nil, 0]
    end
  end
end
