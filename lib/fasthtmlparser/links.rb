# frozen_string_literal: true

module FastHtmlParser
  # @api private A parsed URL (net/url's URL); every string is binary.
  class Url
    attr_accessor :scheme, :opaque, :user, :host, :path, :raw_path, :force_query, :raw_query, :fragment, :raw_fragment

    def initialize
      @scheme = Chars::EMPTY
      @opaque = Chars::EMPTY
      @user = nil # the userinfo as written back (escaped), or nil
      @host = Chars::EMPTY
      @path = Chars::EMPTY # decoded
      @raw_path = Chars::EMPTY # the path as written, when it differs from the default escaping of path
      @force_query = false
      @raw_query = Chars::EMPTY
      @fragment = Chars::EMPTY # decoded
      @raw_fragment = Chars::EMPTY
    end
  end

  # @api private Links: href / src made absolute against the page URL, written as .NET's System.Uri writes them.
  #
  # Resolution follows RFC 3986 the way the Go port does it (net/url: Parse + ResolveReference), byte for byte.
  module Links
    class UrlError < StandardError; end

    MODE_PATH = 0
    MODE_HOST = 1
    MODE_USER_PASSWORD = 2
    MODE_FRAGMENT = 3

    DEFAULT_PORTS = { "http" => "80", "https" => "443", "ftp" => "21", "ws" => "80", "wss" => "443" }.freeze
    RESERVED_FOR_DISPLAY = "%/?#[]@:!$&'()*+,;="
    UPPER_HEX = "0123456789ABCDEF"
    HOST_ALLOWED = "!$&'()*+,;=:[]<>\""
    VALID_ENCODED = "!$&'()*+,;=:@[]%"
    USERINFO = /\A[a-zA-Z0-9\-._:~!$&'()*+,;=%@]*\z/n
    CONTROL = /[\x00-\x1f\x7f]/n

    # escape decisions by byte, per mode
    SHOULD_ESCAPE = Array.new(4) do |mode|
      Array.new(256) do |c|
        ch = c.chr
        if (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39)
          false
        elsif mode == MODE_HOST && HOST_ALLOWED.include?(ch)
          false
        elsif "-_.~".include?(ch)
          false
        elsif "$&+,/:;=?@".include?(ch) && mode != MODE_HOST
          case mode
          when MODE_PATH then ch == "?"
          when MODE_USER_PASSWORD then ch == "@" || ch == "/" || ch == "?" || ch == ":"
          else false
          end
        elsif mode == MODE_FRAGMENT && "!()*".include?(ch)
          false
        else
          true
        end
      end.freeze
    end.freeze

    module_function

    def should_escape?(c, mode)
      SHOULD_ESCAPE[mode][c]
    end

    def hex?(c)
      Chars.hex_byte?(c)
    end

    def unhex(c)
      c <= 57 ? c - 48 : (c | 0x20) - 87
    end

    # net/url unescape; raises UrlError on a malformed URL.
    def unescape(s, mode)
      count = 0
      n = s.bytesize
      i = 0
      while i < n
        c = s.getbyte(i)
        if c == 37
          count += 1
          raise UrlError, "invalid URL escape" if i + 2 >= n || !hex?(s.getbyte(i + 1)) || !hex?(s.getbyte(i + 2))
          # in the host, %-encoding is only for non-ASCII bytes (and %25)
          if mode == MODE_HOST && unhex(s.getbyte(i + 1)) < 8 && s.byteslice(i, 3) != "%25"
            raise UrlError, "invalid URL escape"
          end

          i += 3
        else
          raise UrlError, "invalid character in host name" if mode == MODE_HOST && c < 0x80 && should_escape?(c, mode)

          i += 1
        end
      end
      return s if count.zero?

      out = String.new(capacity: n, encoding: Encoding::BINARY)
      i = 0
      while i < n
        c = s.getbyte(i)
        if c == 37
          out << ((unhex(s.getbyte(i + 1)) << 4) | unhex(s.getbyte(i + 2)))
          i += 3
        else
          out << c
          i += 1
        end
      end
      out
    end

    def escape(s, mode)
      table = SHOULD_ESCAPE[mode]
      out = nil
      from = 0
      n = s.bytesize
      i = 0
      while i < n
        c = s.getbyte(i)
        if table[c]
          out ||= String.new(capacity: n + 16, encoding: Encoding::BINARY)
          out << s.byteslice(from, i - from) << "%" << UPPER_HEX[c >> 4] << UPPER_HEX[c & 15]
          from = i + 1
        end
        i += 1
      end
      return s if out.nil?

      out << s.byteslice(from, n - from)
    end

    def valid_encoded?(s, mode)
      s.each_byte do |c|
        next if VALID_ENCODED.include?(c.chr)
        return false if should_escape?(c, mode)
      end
      true
    end

    # ----- parsing -----

    # [scheme, rest]
    def get_scheme(raw)
      n = raw.bytesize
      i = 0
      while i < n
        c = raw.getbyte(i)
        if Chars.alpha_byte?(c)
          i += 1
          next
        end
        if Chars.digit_byte?(c) || c == 43 || c == 45 || c == 46
          return [Chars::EMPTY, raw] if i.zero?

          i += 1
          next
        end
        if c == 58
          raise UrlError, "missing protocol scheme" if i.zero?

          return [raw.byteslice(0, i), raw.byteslice(i + 1, n - i - 1)]
        end
        return [Chars::EMPTY, raw]
      end
      [Chars::EMPTY, raw]
    end

    def set_path(u, p)
      u.path = unescape(p, MODE_PATH)
      u.raw_path = escape(u.path, MODE_PATH) == p ? Chars::EMPTY : p
    end

    def escaped_path(u)
      if !u.raw_path.empty? && valid_encoded?(u.raw_path, MODE_PATH)
        begin
          return u.raw_path if unescape(u.raw_path, MODE_PATH) == u.path
        rescue UrlError
          # fall through
        end
      end
      return "*" if u.path == "*"

      escape(u.path, MODE_PATH)
    end

    def escaped_fragment(u)
      if !u.raw_fragment.empty? && valid_encoded?(u.raw_fragment, MODE_FRAGMENT)
        begin
          return u.raw_fragment if unescape(u.raw_fragment, MODE_FRAGMENT) == u.fragment
        rescue UrlError
          # fall through
        end
      end
      escape(u.fragment, MODE_FRAGMENT)
    end

    def valid_optional_port?(port)
      return true if port.empty?
      return false if port.getbyte(0) != 58

      port.byteslice(1, port.bytesize - 1).each_byte.all? { |c| c >= 48 && c <= 57 }
    end

    def parse_host(host)
      if host.start_with?("[")
        i = host.rindex("]")
        raise UrlError, "missing ']' in host" if i.nil?
        raise UrlError, "invalid port" unless valid_optional_port?(host.byteslice(i + 1, host.bytesize - i - 1))
      else
        i = host.rindex(":")
        if i && !valid_optional_port?(host.byteslice(i, host.bytesize - i))
          raise UrlError, "invalid port"
        end
      end
      unescape(host, MODE_HOST)
    end

    def parse_authority(u, authority)
      i = authority.rindex("@")
      u.host = parse_host(i.nil? ? authority : authority.byteslice(i + 1, authority.bytesize - i - 1))
      return if i.nil?

      userinfo = authority.byteslice(0, i)
      raise UrlError, "invalid userinfo" unless USERINFO.match?(userinfo)

      colon = userinfo.index(":")
      if colon.nil?
        u.user = escape(unescape(userinfo, MODE_USER_PASSWORD), MODE_USER_PASSWORD)
      else
        name = unescape(userinfo.byteslice(0, colon), MODE_USER_PASSWORD)
        password = unescape(userinfo.byteslice(colon + 1, userinfo.bytesize - colon - 1), MODE_USER_PASSWORD)
        u.user = escape(name, MODE_USER_PASSWORD) + ":" + escape(password, MODE_USER_PASSWORD)
      end
    end

    # net/url Parse.
    def parse_url(raw_url)
      hash = raw_url.index("#")
      u = parse_no_fragment(hash.nil? ? raw_url : raw_url.byteslice(0, hash))
      if hash
        frag = raw_url.byteslice(hash + 1, raw_url.bytesize - hash - 1)
        u.fragment = unescape(frag, MODE_FRAGMENT)
        u.raw_fragment = escape(u.fragment, MODE_FRAGMENT) == frag ? Chars::EMPTY : frag
      end
      u
    end

    def parse_no_fragment(raw)
      raise UrlError, "invalid control character in URL" if CONTROL.match?(raw)

      u = Url.new
      if raw == "*"
        u.path = "*"
        return u
      end
      scheme, rest = get_scheme(raw)
      u.scheme = scheme.downcase(:ascii)

      q = rest.index("?")
      if q && q == rest.bytesize - 1
        u.force_query = true
        rest = rest.byteslice(0, q)
      elsif q
        u.raw_query = rest.byteslice(q + 1, rest.bytesize - q - 1)
        rest = rest.byteslice(0, q)
      end

      unless rest.start_with?("/")
        unless u.scheme.empty?
          # rootless paths are opaque (RFC 3986)
          u.opaque = rest
          return u
        end
        # a relative-path reference: the first segment cannot contain ':'
        slash = rest.index("/")
        first = slash.nil? ? rest : rest.byteslice(0, slash)
        raise UrlError, "first path segment in URL cannot contain colon" if first.include?(":")
      end

      if (!u.scheme.empty? || !rest.start_with?("///")) && rest.start_with?("//")
        authority = rest.byteslice(2, rest.bytesize - 2)
        rest = Chars::EMPTY
        slash = authority.index("/")
        if slash
          rest = authority.byteslice(slash, authority.bytesize - slash)
          authority = authority.byteslice(0, slash)
        end
        parse_authority(u, authority)
      end
      set_path(u, rest)
      u
    end

    def resolve_path(base, ref)
      full = if ref.empty?
               base
             elsif ref.getbyte(0) != 47
               slash = base.rindex("/")
               (slash.nil? ? +"".b : base.byteslice(0, slash + 1)) + ref
             else
               ref
             end
      return Chars::EMPTY if full.empty?

      dst = +"/".b
      first = true
      remaining = full
      found = true
      elem = Chars::EMPTY
      while found
        slash = remaining.index("/")
        found = !slash.nil?
        elem = found ? remaining.byteslice(0, slash) : remaining
        remaining = found ? remaining.byteslice(slash + 1, remaining.bytesize - slash - 1) : Chars::EMPTY
        if elem == "."
          first = false
          next
        end
        if elem == ".."
          str = dst.byteslice(1, dst.bytesize - 1)
          index = str.rindex("/")
          dst = +"/".b
          if index.nil?
            first = true
          else
            dst << str.byteslice(0, index)
          end
        else
          dst << "/" unless first
          dst << elem
          first = false
        end
      end
      dst << "/" if elem == "." || elem == ".."
      dst = dst.byteslice(1, dst.bytesize - 1) if dst.bytesize > 1 && dst.getbyte(1) == 47
      dst
    end

    # net/url ResolveReference.
    def resolve_reference(base, ref)
      url = ref.dup
      url.scheme = base.scheme if ref.scheme.empty?
      if !ref.scheme.empty? || !ref.host.empty? || !ref.user.nil?
        set_path(url, resolve_path(escaped_path(ref), Chars::EMPTY))
        return url
      end
      unless ref.opaque.empty?
        url.user = nil
        url.host = Chars::EMPTY
        url.path = Chars::EMPTY
        return url
      end
      if ref.path.empty? && !ref.force_query && ref.raw_query.empty?
        url.raw_query = base.raw_query
        if ref.fragment.empty?
          url.fragment = base.fragment
          url.raw_fragment = base.raw_fragment
        end
      end
      if ref.path.empty? && !base.opaque.empty?
        url.opaque = base.opaque
        url.user = nil
        url.host = Chars::EMPTY
        url.path = Chars::EMPTY
        return url
      end
      url.host = base.host
      url.user = base.user
      set_path(url, resolve_path(escaped_path(base), escaped_path(ref)))
      url
    end

    # [host, port]
    def split_host_port(host_port)
      host = host_port
      port = Chars::EMPTY
      colon = host.rindex(":")
      if colon && valid_optional_port?(host.byteslice(colon, host.bytesize - colon))
        port = host.byteslice(colon + 1, host.bytesize - colon - 1)
        host = host.byteslice(0, colon)
      end
      host = host.byteslice(1, host.bytesize - 2) if host.bytesize >= 2 && host.getbyte(0) == 91 && host.getbyte(-1) == 93
      [host, port]
    end

    # Decodes %XX escapes except those of reserved and control characters; escaped bytes of non-ASCII text are decoded
    # when they form valid UTF-8.
    def unescape_for_display(s)
      return s unless s.include?("%")

      out = String.new(capacity: s.bytesize, encoding: Encoding::BINARY)
      n = s.bytesize
      i = 0
      while i < n
        if s.getbyte(i) != 37 || i + 2 >= n || !hex?(s.getbyte(i + 1)) || !hex?(s.getbyte(i + 2))
          out << s.getbyte(i)
          i += 1
          next
        end
        c = (unhex(s.getbyte(i + 1)) << 4) | unhex(s.getbyte(i + 2))
        if c < 0x80
          if c < 0x20 || c == 0x7f || RESERVED_FOR_DISPLAY.include?(c.chr)
            out << s.byteslice(i, 3)
          else
            out << c
          end
          i += 3
          next
        end
        # a run of escaped bytes >= 0x80: decoded together when it is valid UTF-8
        j = i
        run = String.new(encoding: Encoding::BINARY)
        while j + 2 < n && s.getbyte(j) == 37 && hex?(s.getbyte(j + 1)) && hex?(s.getbyte(j + 2))
          v = (unhex(s.getbyte(j + 1)) << 4) | unhex(s.getbyte(j + 2))
          break if v < 0x80

          run << v
          j += 3
        end
        out << (run.dup.force_encoding(Encoding::UTF_8).valid_encoding? ? run : s.byteslice(i, j - i))
        i = j
      end
      out
    end

    # Writes a resolved URL as the .NET version does (System.Uri.ToString): the scheme and host in lower case, no
    # default port, an empty path as "/", and percent-escapes decoded except those of the characters that delimit URL
    # parts ("%2F" stays) and of control characters; non-ASCII text is written as is.
    def display_string(u)
      b = u.scheme.downcase(:ascii) + ":"
      if u.opaque.empty?
        if !u.host.empty? || !u.user.nil?
          b << "//"
          b << u.user << "@" unless u.user.nil?
          host, port = split_host_port(u.host)
          b << Chars.lower(Chars.scrub(host))
          b << ":" << port if !port.empty? && port != DEFAULT_PORTS[u.scheme.downcase(:ascii)]
        end
        path = escaped_path(u)
        path = "/" if path.empty? && !u.host.empty?
        b << unescape_for_display(path)
      else
        b << u.opaque
      end
      b << "?" << unescape_for_display(u.raw_query) if !u.raw_query.empty? || u.force_query
      b << "#" << unescape_for_display(escaped_fragment(u)) unless u.fragment.empty?
      Chars.scrub(b)
    end

    # Parses a page URL with its own scheme and host; nil for anything else.
    def absolute_url(s)
      return nil if s.empty?

      u = parse_url(s)
      return nil if u.scheme.empty? || (u.host.empty? && u.opaque.empty? && !u.scheme.casecmp?("file"))

      u
    rescue UrlError
      nil
    end

    # A link with its own scheme ("https://...", "mailto:...", "file:..."). "/path" and "//host/path" are relative.
    def absolute_link?(link)
      !parse_url(Chars.trim_space(link)).scheme.empty?
    rescue UrlError
      false
    end

    # The raw attribute value with its character references decoded and made absolute against the page.
    # Percent-escapes are part of the URL and are kept. An empty link gives the page URL.
    def correct_link(raw, page_url, base)
      return page_url.dup if raw.empty?

      link = Decode.needs_decoding?(raw) ? Decode.decode(raw, true) : raw
      return link if base.nil? || absolute_link?(link)

      begin
        display_string(resolve_reference(base, parse_url(Chars.trim_space(link))))
      rescue UrlError
        link
      end
    end

    # Everything after the first ':' of a link with the scheme (mailto, tel), or "".
    def after_scheme(raw_href, scheme)
      href = Chars.trim_space(Decode.decode(raw_href, true))
      return +"".b if href.bytesize < scheme.bytesize || !href.byteslice(0, scheme.bytesize).casecmp?(scheme)

      i = href.index(":")
      i.nil? ? +"".b : href.byteslice(i + 1, href.bytesize - i - 1)
    end
  end
end
