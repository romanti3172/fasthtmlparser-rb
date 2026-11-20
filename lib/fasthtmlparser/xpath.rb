# frozen_string_literal: true

module FastHtmlParser
  # @api private A node of the XPath data model over the flat tag list: the root, an element, a comment, a text node
  # (a run of source text between tags) or an attribute (positions in the opening tag).
  class XNode
    ROOT = 0
    ELEMENT = 1
    COMMENT = 2
    TEXT = 3
    ATTRIBUTE = 4

    # tag: element / comment: the tag; text / attribute: the parent element (nil: the root)
    # start: text: first byte; attribute: name start. length: text: length; attribute: name length
    # value_start: attribute: value start (-1 for no value)
    # major, minor: document order and identity: tags and text nodes by their first byte; attributes right after
    # their element
    attr_reader :kind, :doc, :tag, :start, :length, :value_start, :value_length, :major, :minor

    def initialize(kind, doc, tag, start = 0, length = 0, value_start = 0, value_length = 0)
      @kind = kind
      @doc = doc
      @tag = tag
      @start = start
      @length = length
      @value_start = value_start
      @value_length = value_length
      @major = case kind
               when ROOT then -1
               when TEXT then start
               else tag.start
               end
      @minor = kind == ATTRIBUTE ? start : 0
    end

    def self.root(d)
      new(ROOT, d, nil)
    end

    def self.of_tag(n)
      new(n.key == Parser::COMMENT ? COMMENT : ELEMENT, n.doc, n)
    end

    # The first source position the node covers (for following / preceding).
    def range_start
      @kind == ROOT ? -1 : @major
    end

    # The last source position the node covers.
    def range_end
      case @kind
      when ROOT then Float::INFINITY
      when ELEMENT, COMMENT then @tag.end
      when TEXT then @start + @length - 1
      else @tag.start # attribute: the children of its element follow it
      end
    end

    def attr_name
      @doc.source_bytes.byteslice(@start, @length)
    end
  end

  # A compiled XPath 1.0 expression over the flat tag list: the root, elements, comments, text nodes (runs of source
  # text between tags) and attributes (positions in the opening tag). Compile once and reuse it on any number of
  # documents; the string methods (node.xpath(...), doc.xpath_value(...), ...) compile and cache expressions
  # automatically.
  #
  # All axes (except namespace), predicates, |, the operators and the XPath 1.0 functions are supported, plus
  # ends-with(), lower-case() and upper-case(). HTML rules apply: names are case-insensitive, the string-value of an
  # element is its visible text (as HtmlNode#text), attribute values and text are decoded. Variables are not
  # supported. On a node, relative paths start at the node; '/' and '//' search the whole document.
  class XPathQuery
    # value types
    TYPE_NODE_SET = 0
    TYPE_NUMBER = 1
    TYPE_STRING = 2
    TYPE_BOOLEAN = 3
    TYPE_NAMES = %w[node-set number string boolean].freeze

    # expressions
    E_LITERAL = 0 # value
    E_NUMBER = 1 # value
    E_AND = 2 # l, r
    E_OR = 3 # l, r
    E_COMPARE = 4 # cmp, l, r
    E_ARITH = 5 # arith, l, r
    E_NEGATE = 6 # e
    E_UNION = 7 # l, r
    E_ATTR_EQUALS = 8 # name, value, negate: @name = 'literal' compared in place
    E_ATTR_EXISTS = 9 # name: [@name]
    E_PATH = 10 # start (expr or nil), absolute, steps; attr: a bare @name
    E_FILTER = 11 # primary, preds
    E_FUNCTION = 12 # fn, args
    # fn, l (prefix), name, r (suffix), value (needle): contains/starts-with/ends-with(concat(l, @name, r), value),
    # tested on the attribute in place (prefix and suffix may be empty)
    E_ATTR_TEST = 13

    OP_EQ = 0
    OP_NEQ = 1
    OP_LT = 2
    OP_LE = 3
    OP_GT = 4
    OP_GE = 5

    ARITH_ADD = 0
    ARITH_SUB = 1
    ARITH_MUL = 2
    ARITH_DIV = 3
    ARITH_MOD = 4

    # node tests
    TK_NAME = 0
    TK_PREFIX = 1 # dc:*
    TK_WILDCARD = 2 # *
    TK_NODE = 3 # node()
    TK_TEXT = 4 # text()
    TK_COMMENT = 5 # comment()
    TK_PI = 6 # processing-instruction(): never matches
    TK_CONTAINER = 7 # internal: the root and elements (// before a child or attribute step)

    AXIS_CHILD = 0
    AXIS_DESCENDANT = 1
    AXIS_DESCENDANT_OR_SELF = 2
    AXIS_SELF = 3
    AXIS_PARENT = 4
    AXIS_ANCESTOR = 5
    AXIS_ANCESTOR_OR_SELF = 6
    AXIS_FOLLOWING_SIBLING = 7
    AXIS_PRECEDING_SIBLING = 8
    AXIS_FOLLOWING = 9
    AXIS_PRECEDING = 10
    AXIS_ATTRIBUTE = 11

    # @api private
    Expr = Struct.new(:op, :type, :pos, :value, :l, :r, :cmp, :arith, :e, :name, :negate, :start, :absolute, :steps,
                      :primary, :preds, :fn, :args, :attr, keyword_init: true)
    # @api private
    Step = Struct.new(:axis, :test, :preds, :positional)
    # @api private
    NodeTest = Struct.new(:k, :name, :q)

    ANY_NODE_TEST = NodeTest.new(TK_NODE, Chars::EMPTY, nil).freeze
    CONTAINERS_TEST = NodeTest.new(TK_CONTAINER, Chars::EMPTY, nil).freeze

    @cache = {}
    @cache_lock = Mutex.new

    def initialize(expression, expr)
      @expression = expression
      @expr = expr
      freeze
    end

    # Compiles an XPath 1.0 expression; raises XPathError on an invalid one.
    def self.compile(expression)
      s = Chars.b(expression.to_s)
      new(expression.to_s.dup.freeze, XPathCompiler.new(s).parse)
    end

    # @api private compiles and caches
    def self.cached(expression)
      q = @cache[expression]
      return q if q

      q = compile(expression)
      @cache_lock.synchronize do
        @cache.clear if @cache.size >= 1024 # dynamically built expressions must not grow the cache forever
        @cache[expression.frozen? ? expression : expression.dup.freeze] = q
      end
      q
    end

    # The source of the expression.
    attr_reader :expression

    def to_s
      @expression
    end

    def inspect
      "#<#{self.class.name} #{@expression}>"
    end

    # The selected tags (elements and comments) in document order, evaluated on the document. Raises XPathError when
    # the expression does not give a node-set (use value).
    def nodes(doc)
      tags_of(XNode.root(doc))
    end

    # nodes evaluated on a tag: relative paths start at it.
    def nodes_from(node)
      tags_of(XNode.of_tag(node))
    end

    # The string-values of the selected nodes, or the result of an expression that gives a number, string or boolean
    # (count(//a), concat(...)) as one value.
    def values(doc)
      values_of(XNode.root(doc))
    end

    # values evaluated on a tag.
    def values_from(node)
      values_of(XNode.of_tag(node))
    end

    # The string-value of the first selected node, or the result of the expression; nil when it selects no node.
    def value(doc)
      value_of(XNode.root(doc))
    end

    # value evaluated on a tag.
    def value_from(node)
      value_of(XNode.of_tag(node))
    end

    # The shortest round-trip digits, written without an exponent (XPath has none), as JavaScript writes a number.
    def self.number_to_string(d)
      return "NaN" if d.nan?
      return d > 0 ? "Infinity" : "-Infinity" if d.infinite?
      return "0" if d == 0
      return d.to_i.to_s if d == d.floor && d.abs < 1e15

      # the fewest significant digits that read back as d (Float#to_s), placed without an exponent
      mantissa, exponent = d.abs.to_s.split("e")
      int_part, frac = mantissa.split(".")
      digits = int_part + frac.to_s
      point_at = int_part.size + exponent.to_i
      while digits.size > 1 && digits.start_with?("0")
        digits = digits[1..]
        point_at -= 1
      end
      digits = digits.sub(/0+\z/, "")
      len = digits.size
      out = d < 0 ? +"-" : +""
      if point_at <= 0
        out << "0." << ("0" * -point_at) << digits
      elsif point_at >= len
        out << digits << ("0" * (point_at - len))
      else
        out << digits[0, point_at] << "." << digits[point_at..]
      end
      out
    end

    private

    def tags_of(context)
      if @expr.type != TYPE_NODE_SET
        raise XPathError, "the XPath #{Chars.quote(@expression)} gives a #{TYPE_NAMES[@expr.type]}, not tags; " \
                          "use xpath_value"
      end
      out = []
      XPathEvaluator.new(context.doc).evaluate(@expr, context).each do |n|
        out << n.tag if n.kind == XNode::ELEMENT || n.kind == XNode::COMMENT
      end
      out
    end

    def values_of(context)
      ev = XPathEvaluator.new(context.doc)
      result = ev.evaluate(@expr, context)
      return [Chars.u(ev.to_str(result))] unless result.is_a?(Array)

      result.map { |n| Chars.u(ev.string_value(n)) }
    end

    def value_of(context)
      ev = XPathEvaluator.new(context.doc)
      result = ev.evaluate(@expr, context)
      if result.is_a?(Array)
        return result.empty? ? nil : Chars.u(ev.string_value(result[0]))
      end

      Chars.u(ev.to_str(result))
    end
  end

  # @api private The evaluation of one expression on one document: values are a node-set (an Array of XNode), a
  # Float, a String (binary) or true / false.
  class XPathEvaluator
    X = XPathQuery
    NAN = Float::NAN
    INF = Float::INFINITY
    EMPTY = Chars::EMPTY
    NUMBER_CHARS = /\A-?[0-9.]*\z/n

    def initialize(doc)
      @doc = doc
      @all = nil
    end

    def evaluate(expr, context)
      eval_expr(expr, context, 1, 1)
    end

    # ----- node tests -----

    def matches_tag?(test, n)
      matches_tag_at?(test, n.doc, n.index)
    end

    # The node test on the tag at index i, read from the arrays of the document.
    def matches_tag_at?(test, d, i)
      case test.k
      when 0 # TK_NAME
        test.q.name_matches_at?(d, i)
      when 1 # TK_PREFIX
        k = d.keys[i]
        name = k >= 0 ? TagNames::NAMES[k] : d.customs[i]
        len = test.name.bytesize
        CssQuery.element_at?(d, i) && name.bytesize >= len && Chars.equal_fold(name.byteslice(0, len), test.name)
      when 2, 7 # TK_WILDCARD, TK_CONTAINER
        CssQuery.element_at?(d, i)
      when 3 # TK_NODE
        CssQuery.element_at?(d, i) || d.keys[i] == Parser::COMMENT
      when 5 # TK_COMMENT
        d.keys[i] == Parser::COMMENT
      else
        false
      end
    end

    def matches_text?(test)
      test.k == X::TK_NODE || test.k == X::TK_TEXT
    end

    def matches_tags?(test)
      test.k != X::TK_TEXT && test.k != X::TK_PI
    end

    def matches_attribute?(test, attribute)
      case test.k
      when 0 # TK_NAME
        Chars.equal_fold(attribute, test.name)
      when 1 # TK_PREFIX
        len = test.name.bytesize
        attribute.bytesize >= len && Chars.equal_fold(attribute.byteslice(0, len), test.name)
      when 2, 3 # TK_WILDCARD, TK_NODE
        true
      else
        false
      end
    end

    def matches?(test, x, attribute_axis)
      case x.kind
      when 0 # ROOT
        test.k == X::TK_NODE || test.k == X::TK_CONTAINER
      when 1, 2 # ELEMENT, COMMENT
        matches_tag?(test, x.tag)
      when 3 # TEXT
        matches_text?(test)
      else
        return matches_attribute?(test, x.attr_name) if attribute_axis

        test.k == X::TK_NODE
      end
    end

    # ----- navigation -----

    # Appends the children of the root or an element that match the test, text nodes included, in document order.
    def add_children(x, test, out)
      want_text = matches_text?(test)
      want_tags = matches_tags?(test)
      return if !want_text && !want_tags

      doc = x.doc
      if x.kind == XNode::ROOT
        first = 0
        end_ = INF
        child_depth = 0
        p = 0
        text_end = doc.source_bytes.bytesize
      elsif x.kind == XNode::ELEMENT && x.tag.inner_start > 0 && x.tag.inner_end > 0
        t = x.tag
        first = t.index + 1
        end_ = t.end
        child_depth = t.depth + 1
        p = t.inner_start
        text_end = t.inner_end + 1
      else
        return
      end
      ends = doc.ends
      depths = doc.depths
      starts = doc.starts
      parent = x.kind == XNode::ELEMENT ? x.tag : nil
      count = doc.size
      i = first
      while i < count
        break if ends[i] > end_

        if depths[i] == child_depth
          start = starts[i]
          if want_text && start > p
            e = start < text_end ? start : text_end
            out << XNode.new(XNode::TEXT, doc, parent, p, e - p) if e > p
          end
          out << XNode.of_tag(doc.at(i)) if want_tags && matches_tag_at?(test, doc, i)
          p = ends[i] + 1
        end
        i += 1
      end
      out << XNode.new(XNode::TEXT, doc, parent, p, text_end - p) if want_text && text_end > p
    end

    # Appends the descendants of the root or an element that match the test, in document order.
    def add_descendants(x, test, out)
      if matches_text?(test)
        add_descendants_with_text(x, test, out)
        return
      end
      return unless matches_tags?(test)

      if x.kind == XNode::ROOT
        first = 0
        end_ = INF
      elsif x.kind == XNode::ELEMENT && x.tag.inner_start > 0 && x.tag.inner_end > 0
        first = x.tag.index + 1
        end_ = x.tag.end
      else
        return
      end
      # tags only: one linear scan of the flat list
      d = x.doc
      ends = d.ends
      count = d.size
      i = first
      if test.k == X::TK_NAME
        q = test.q
        qk = q.key
        keys = d.keys
        named = !q.tag_name.empty?
        while i < count
          break if ends[i] > end_

          # a known name: one int compare on the arrays
          k = keys[i]
          if qk >= 0 ? k == qk || (k < 0 && named && Chars.equal_fold(d.customs[i], q.tag_name)) : q.name_matches_at?(d, i)
            out << XNode.new(XNode::ELEMENT, d, d.at(i))
          end
          i += 1
        end
        return
      end
      while i < count
        break if ends[i] > end_

        out << XNode.of_tag(d.at(i)) if matches_tag_at?(test, d, i)
        i += 1
      end
    end

    def add_descendants_with_text(x, test, out)
      children = []
      add_children(x, X::ANY_NODE_TEST, children)
      children.each do |child|
        out << child if matches?(test, child, false)
        add_descendants_with_text(child, test, out) if child.kind == XNode::ELEMENT
      end
    end

    def parent_node(x)
      case x.kind
      when 0 # ROOT
        nil
      when 3, 4 # TEXT, ATTRIBUTE
        x.tag.nil? ? XNode.root(x.doc) : XNode.of_tag(x.tag)
      else
        t = x.tag
        t.depth > 0 && t.parent_index >= 0 ? XNode.of_tag(x.doc.at(t.parent_index)) : XNode.root(x.doc)
      end
    end

    def add_attributes(x, test, out)
      return if x.kind != XNode::ELEMENT

      s = AttrScanner.new(x.tag)
      while s.next?
        if matches_attribute?(test, s.name)
          out << XNode.new(XNode::ATTRIBUTE, x.doc, x.tag, s.name_start, s.name_length, s.value_start, s.value_length)
        end
      end
    end

    # The raw value of the first attribute with the name (lower case); nil when the element has none.
    def attribute_of(x, name)
      return nil if x.kind != XNode::ELEMENT

      raw = Attrs.attr_raw(x.tag, name)
      return raw unless raw.empty?

      Attrs.has_attribute?(x.tag, name) ? raw : nil
    end

    # The root and elements give their visible text; text nodes and attributes their decoded value; comments their
    # content.
    def string_value(x)
      case x.kind
      when 0 # ROOT
        Text.clear_tags(x.doc.source_bytes)
      when 1 # ELEMENT
        x.tag.text_bytes
      when 4 # ATTRIBUTE
        x.value_start < 0 ? +"".b : Decode.decode(x.doc.source_bytes.byteslice(x.value_start, x.value_length), true)
      when 3 # TEXT
        text = x.doc.source_bytes.byteslice(x.start, x.length)
        return Decode.normalize_newlines(text) if x.tag && Parser.raw_text?(x.tag.key)

        Decode.decode(text, false)
      else
        # comment
        t = x.tag
        source = Chars.slice(t.doc.source_bytes, t.start, t.end + 1)
        source = source.byteslice(4, source.bytesize - 4) if source.start_with?("<!--")
        source = source.byteslice(0, source.bytesize - 3) if source.end_with?("-->")
        source
      end
    end

    # name() / local-name(): the lower-case tag or attribute name; "" for other nodes.
    def node_name(x)
      return x.tag.name_bytes if x.kind == XNode::ELEMENT
      return Chars.lower(x.attr_name) if x.kind == XNode::ATTRIBUTE

      EMPTY
    end

    # ----- values -----

    def to_boolean(v)
      case v
      when true, false then v
      when Float then v != 0 && !v.nan?
      when String then !v.empty?
      else !v.empty?
      end
    end

    def to_number(v)
      case v
      when Float then v
      when true then 1.0
      when false then 0.0
      when String then string_to_number(v)
      else v.empty? ? NAN : string_to_number(string_value(v[0]))
      end
    end

    # Optional '-', digits with an optional decimal point; anything else is NaN.
    def string_to_number(value)
      s = Chars.trim_space(value)
      return NAN unless NUMBER_CHARS.match?(s)

      body = s.start_with?("-") ? s.byteslice(1, s.bytesize - 1) : s
      dots = body.count(".")
      return NAN if dots > 1 || (body.bytesize - dots).zero?

      s.to_f
    end

    def to_str(v)
      case v
      when String then v
      when true then "true"
      when false then "false"
      when Float then X.number_to_string(v)
      else v.empty? ? EMPTY : string_value(v[0])
      end
    end

    def compare_keys(a, b)
      c = a.major <=> b.major
      c == 0 ? a.minor <=> b.minor : c
    end

    # Puts the nodes in document order without duplicates.
    def sort_unique(nodes)
      count = nodes.size
      return nodes if count < 2

      sorted = true
      i = 1
      while i < count
        a = nodes[i - 1]
        b = nodes[i]
        if a.major > b.major || (a.major == b.major && a.minor >= b.minor)
          sorted = false
          break
        end
        i += 1
      end
      return nodes if sorted

      # stable: ties keep their order
      nodes = nodes.each_with_index.sort_by { |n, k| [n.major, n.minor, k] }.map(&:first)
      out = [nodes[0]]
      last = nodes[0]
      i = 1
      while i < count
        n = nodes[i]
        if n.major != last.major || n.minor != last.minor
          out << n
          last = n
        end
        i += 1
      end
      out
    end

    def all_nodes
      return @all if @all

      all = []
      add_descendants(XNode.root(@doc), X::ANY_NODE_TEST, all)
      @all = all
    end

    # ----- evaluation -----

    def eval_nodes(e, node, position, size)
      v = eval_expr(e, node, position, size)
      return v if v.is_a?(Array)

      raise XPathError, "the XPath expression does not give a node-set"
    end

    def eval_string(e, node, position, size)
      if e.attr
        # a bare @name: the string-value of the first such attribute, read in place
        raw = node.kind == XNode::ELEMENT ? Attrs.attr_raw(node.tag, e.attr) : EMPTY
        return Decode.needs_decoding?(raw) ? Decode.decode(raw, true) : raw
      end
      to_str(eval_expr(e, node, position, size))
    end

    def eval_number(e, node, position, size)
      to_number(eval_expr(e, node, position, size))
    end

    def eval_bool(e, node, position, size)
      case e.op
      when 0 # E_LITERAL
        !e.value.empty?
      when 2 # E_AND
        eval_bool(e.l, node, position, size) && eval_bool(e.r, node, position, size)
      when 3 # E_OR
        eval_bool(e.l, node, position, size) || eval_bool(e.r, node, position, size)
      when 4 # E_COMPARE
        compare(e.cmp, eval_expr(e.l, node, position, size), eval_expr(e.r, node, position, size))
      when 8 # E_ATTR_EQUALS
        # '!=' is true when the attribute exists and differs (a missing attribute is an empty node-set)
        raw = attribute_of(node, e.name)
        !raw.nil? && Attrs.attr_equals?(raw, e.value) != e.negate
      when 9 # E_ATTR_EXISTS
        !attribute_of(node, e.name).nil?
      when 13 # E_ATTR_TEST
        # a missing attribute is an empty node-set, whose string-value is ""
        raw = attribute_of(node, e.name) || EMPTY
        raw = Decode.decode(raw, true) if Decode.needs_decoding?(raw)
        value = e.l.empty? && e.r.empty? ? raw : String.new(e.l, encoding: Encoding::BINARY) << raw << e.r
        case e.fn
        when "contains" then value.include?(e.value)
        when "starts-with" then value.start_with?(e.value)
        else value.end_with?(e.value)
        end
      else
        to_boolean(eval_expr(e, node, position, size))
      end
    end

    # A number compares with the position, anything else is converted to boolean.
    def eval_predicate(e, node, position, size)
      return eval_bool(e, node, position, size) if e.type == X::TYPE_BOOLEAN

      v = eval_expr(e, node, position, size)
      return v == position if v.is_a?(Float)

      to_boolean(v)
    end

    def eval_expr(e, node, position, size)
      case e.op
      when 0, 1 # E_LITERAL, E_NUMBER
        e.value
      when 2, 3, 4, 8, 9, 13 # E_AND, E_OR, E_COMPARE, E_ATTR_EQUALS, E_ATTR_EXISTS, E_ATTR_TEST
        eval_bool(e, node, position, size)
      when 5 # E_ARITH
        x = eval_number(e.l, node, position, size)
        y = eval_number(e.r, node, position, size)
        case e.arith
        when 0 then x + y # ARITH_ADD
        when 1 then x - y # ARITH_SUB
        when 2 then x * y # ARITH_MUL
        when 3 then x / y # ARITH_DIV
        else fmod(x, y)
        end
      when 6 # E_NEGATE
        -eval_number(e.e, node, position, size)
      when 7 # E_UNION
        a = eval_nodes(e.l, node, position, size)
        b = eval_nodes(e.r, node, position, size)
        sort_unique(a + b)
      when 10 # E_PATH
        current = if e.start
                    eval_nodes(e.start, node, position, size)
                  elsif e.absolute
                    [XNode.root(@doc)]
                  else
                    [node]
                  end
        e.steps.each do |s|
          break if current.empty?

          current = apply_step(s, current)
        end
        current
      when 11 # E_FILTER
        filter(eval_nodes(e.primary, node, position, size), e.preds)
      else
        eval_function(e, node, position, size)
      end
    end

    # C fmod: the remainder has the sign of x.
    def fmod(x, y)
      return NAN if x.nan? || y.nan? || x.infinite? || y == 0
      return x if y.infinite?

      r = x % y
      r -= y if r != 0 && ((r < 0) != (x < 0))
      r
    end

    def compare(op, a, b)
      if a.is_a?(Array)
        if b.is_a?(Array)
          return false if a.empty? || b.empty?

          values_b = b.map { |n| string_value(n) }
          a.each do |x|
            value = string_value(x)
            values_b.each { |other| return true if compare_atoms(op, value, other) }
          end
          return false
        end
        return compare_with_nodes(op, a, b, true)
      end
      return compare_with_nodes(op, b, a, false) if b.is_a?(Array)

      compare_atoms(op, a, b)
    end

    def compare_with_nodes(op, nodes, other, nodes_on_left)
      if other == true || other == false
        as_bool = !nodes.empty?
        return nodes_on_left ? compare_atoms(op, as_bool, other) : compare_atoms(op, other, as_bool)
      end
      is_number = other.is_a?(Float)
      nodes.each do |n|
        s = string_value(n)
        value = is_number ? string_to_number(s) : s
        return true if nodes_on_left ? compare_atoms(op, value, other) : compare_atoms(op, other, value)
      end
      false
    end

    def compare_atoms(op, a, b)
      if op == X::OP_EQ || op == X::OP_NEQ
        eq = if a == true || a == false || b == true || b == false
               to_boolean(a) == to_boolean(b)
             elsif a.is_a?(Float) || b.is_a?(Float)
               to_number(a) == to_number(b)
             else
               to_str(a) == to_str(b)
             end
        return eq == (op == X::OP_EQ)
      end
      x = to_number(a)
      y = to_number(b)
      case op
      when 2 then x < y # OP_LT
      when 3 then x <= y # OP_LE
      when 4 then x > y # OP_GT
      else x >= y
      end
    end

    # ----- steps -----

    def reverse?(axis)
      axis == X::AXIS_ANCESTOR || axis == X::AXIS_ANCESTOR_OR_SELF || axis == X::AXIS_PRECEDING ||
        axis == X::AXIS_PRECEDING_SIBLING
    end

    def apply_step(step, input)
      if input.size == 1
        out = []
        select_from(step, input[0], out)
        return out
      end

      # Nested input nodes (//div//a on divs inside divs, //a/ancestor::* on links in one list) give the same nodes
      # again and again: n nested nodes would collect about n^2 nodes before the duplicates are removed. When the
      # predicates do not depend on the position, a node passes them or not whichever input node it comes from, so
      # the input nodes whose results are already collected are skipped: the work stays linear.
      unless step.positional
        case step.axis
        when 1, 2 # AXIS_DESCENDANT, AXIS_DESCENDANT_OR_SELF
          if !matches_text?(step.test) && in_document_order?(input)
            return sort_unique(select_descendants_of_nested(step, input))
          end
        when 5, 6 # AXIS_ANCESTOR, AXIS_ANCESTOR_OR_SELF
          return sort_unique(select_shared_ancestors(step, input))
        end
      end

      out = []
      input.each { |x| select_from(step, x, out) }
      sort_unique(out)
    end

    # The descendant axes (tags only) on input nodes in document order. A tag that lies in the part of the tag list
    # already scanned for an earlier input node is skipped: that scan has tested it and every tag its own scan would
    # test.
    def select_descendants_of_nested(step, input)
      ends = @doc.ends
      count = @doc.size
      out = []
      scanned_to = -1 # the tags before this index were scanned for an earlier input node
      input.each do |x|
        if x.kind == XNode::ELEMENT || x.kind == XNode::COMMENT
          t = x.tag
          next if t.index < scanned_to

          select_from(step, x, out)
          # where add_descendants stops for this tag
          if x.kind == XNode::ELEMENT && t.inner_start > 0 && t.inner_end > 0
            k = t.index + 1
            k += 1 while k < count && ends[k] <= t.end
            scanned_to = k if k > scanned_to
          end
        else
          select_from(step, x, out)
          scanned_to = INF if x.kind == XNode::ROOT
        end
      end
      out
    end

    # The walk up from an input node stops at an ancestor already reached from an earlier one, because that walk has
    # gone on to the root. Only the root and elements are marked: they are the only parents.
    def select_shared_ancestors(step, input)
      visited = {}
      out = []
      test = step.test
      input.each do |x|
        start = out.size
        current = x
        if step.axis == X::AXIS_ANCESTOR_OR_SELF
          container = current.kind == XNode::ROOT || current.kind == XNode::ELEMENT
          next if container && visited[current.major]

          visited[current.major] = true if container
          out << current if matches?(test, current, false)
        end
        loop do
          p = parent_node(current)
          break if p.nil? || visited[p.major]

          visited[p.major] = true
          current = p
          out << current if matches?(test, current, false)
        end
        if !step.preds.empty? && out.size > start
          kept = filter(out[start..], step.preds)
          out[start..] = kept
        end
      end
      out
    end

    # Appends the nodes of the axis that pass the test and the predicates, in document order.
    def select_from(step, x, out)
      reverse = reverse?(step.axis)
      if step.preds.empty? && !reverse
        collect(step, x, out)
        return
      end
      selected = []
      collect(step, x, selected)
      selected = filter(selected, step.preds)
      selected.reverse! if reverse
      out.concat(selected)
    end

    # Appends the nodes of the axis that pass the node test, in axis order (reverse axes: nearest first).
    def collect(step, x, out)
      test = step.test
      case step.axis
      when 0 # AXIS_CHILD
        add_children(x, test, out)
      when 1 # AXIS_DESCENDANT
        add_descendants(x, test, out)
      when 2 # AXIS_DESCENDANT_OR_SELF
        out << x if matches?(test, x, false)
        add_descendants(x, test, out)
      when 3 # AXIS_SELF
        out << x if matches?(test, x, false)
      when 4 # AXIS_PARENT
        p = parent_node(x)
        out << p if !p.nil? && matches?(test, p, false)
      when 5, 6 # AXIS_ANCESTOR, AXIS_ANCESTOR_OR_SELF
        current = x
        out << current if step.axis == X::AXIS_ANCESTOR_OR_SELF && matches?(test, current, false)
        until (current = parent_node(current)).nil?
          out << current if matches?(test, current, false)
        end
      when 7, 8 # AXIS_FOLLOWING_SIBLING, AXIS_PRECEDING_SIBLING
        collect_siblings(x, test, out, step.axis == X::AXIS_FOLLOWING_SIBLING)
      when 9 # AXIS_FOLLOWING
        collect_following(x, test, out)
      when 10 # AXIS_PRECEDING
        collect_preceding(x, test, out)
      when 11 # AXIS_ATTRIBUTE
        add_attributes(x, test, out)
      end
    end

    def in_document_order?(nodes)
      i = 1
      while i < nodes.size
        return false if compare_keys(nodes[i - 1], nodes[i]) >= 0

        i += 1
      end
      true
    end

    def collect_siblings(x, test, out, following)
      return if x.kind == XNode::ROOT || x.kind == XNode::ATTRIBUTE

      if !matches_text?(test) && x.kind != XNode::TEXT
        # tags only: walk the flat list; deeper tags are inside the siblings, a shallower one ends the parent
        t = x.tag
        d = t.doc
        depths = d.depths
        count = d.size
        step_by = following ? 1 : -1
        i = t.index + step_by
        while i >= 0 && i < count
          break if depths[i] < t.depth

          out << XNode.of_tag(d.at(i)) if depths[i] == t.depth && matches_tag_at?(test, d, i)
          i += step_by
        end
        return
      end
      parent = parent_node(x)
      return if parent.nil?

      siblings = []
      add_children(parent, X::ANY_NODE_TEST, siblings)
      index = siblings.index { |s| compare_keys(s, x).zero? }
      return if index.nil?

      if following
        ((index + 1)...siblings.size).each { |i| out << siblings[i] if matches?(test, siblings[i], false) }
      else
        (index - 1).downto(0) { |i| out << siblings[i] if matches?(test, siblings[i], false) }
      end
    end

    def collect_following(x, test, out)
      return if x.kind == XNode::ROOT

      after = x.range_end
      if matches_text?(test)
        all_nodes.each { |n| out << n if n.range_start > after && matches?(test, n, false) }
        return
      end
      d = @doc
      starts = d.starts
      i = x.kind == XNode::ELEMENT || x.kind == XNode::COMMENT ? x.tag.index + 1 : 0
      count = d.size
      while i < count
        out << XNode.of_tag(d.at(i)) if starts[i] > after && matches_tag_at?(test, d, i)
        i += 1
      end
    end

    def collect_preceding(x, test, out)
      return if x.kind == XNode::ROOT

      before = x.range_start
      if matches_text?(test)
        all = all_nodes
        (all.size - 1).downto(0) { |i| out << all[i] if all[i].range_end < before && matches?(test, all[i], false) }
        return
      end
      d = @doc
      ends = d.ends
      i = x.kind == XNode::ELEMENT || x.kind == XNode::COMMENT ? x.tag.index - 1 : d.size - 1
      while i >= 0
        out << XNode.of_tag(d.at(i)) if ends[i] < before && matches_tag_at?(test, d, i)
        i -= 1
      end
    end

    # Applies the predicates one after another; positions are 1-based in the order of the list.
    def filter(nodes, predicates)
      predicates.each do |p|
        size = nodes.size
        kept = []
        nodes.each_with_index { |n, i| kept << n if eval_predicate(p, n, i + 1, size) }
        nodes = kept
      end
      nodes
    end

    # ----- functions -----

    def round(v)
      return v if v.nan? || v.infinite?

      float_floor(v + 0.5)
    end

    def float_floor(v)
      return v if v.nan? || v.infinite?

      r = v.floor.to_f
      r == 0 && v < 0 ? -0.0 : r
    end

    def float_ceil(v)
      return v if v.nan? || v.infinite?

      r = v.ceil.to_f
      r == 0 && v < 0 ? -0.0 : r
    end

    # Splits on Unicode whitespace and joins with one space.
    def normalize_space(s)
      s.split(Chars::SPACE_RUNS).reject(&:empty?).join(" ").b
    end

    def eval_function(e, node, position, size)
      args = e.args
      case e.fn
      when "last"
        size.to_f
      when "position"
        position.to_f
      when "count"
        eval_nodes(args[0], node, position, size).size.to_f
      when "name", "local-name"
        name = EMPTY
        if args.empty?
          name = node_name(node)
        else
          set = eval_nodes(args[0], node, position, size)
          name = node_name(set[0]) unless set.empty?
        end
        if e.fn == "local-name"
          colon = name.rindex(":")
          return colon.nil? ? name : name.byteslice(colon + 1, name.bytesize - colon - 1)
        end
        name
      when "string"
        args.empty? ? string_value(node) : eval_string(args[0], node, position, size)
      when "concat"
        s = String.new(encoding: Encoding::BINARY)
        args.each { |a| s << eval_string(a, node, position, size) }
        s
      when "starts-with"
        eval_string(args[0], node, position, size).start_with?(eval_string(args[1], node, position, size))
      when "ends-with"
        eval_string(args[0], node, position, size).end_with?(eval_string(args[1], node, position, size))
      when "contains"
        eval_string(args[0], node, position, size).include?(eval_string(args[1], node, position, size))
      when "substring-before"
        s = eval_string(args[0], node, position, size)
        i = s.index(eval_string(args[1], node, position, size))
        i.nil? ? EMPTY : s.byteslice(0, i)
      when "substring-after"
        s = eval_string(args[0], node, position, size)
        t = eval_string(args[1], node, position, size)
        i = s.index(t)
        i.nil? ? EMPTY : s.byteslice(i + t.bytesize, s.bytesize - i - t.bytesize)
      when "substring"
        substring(e, node, position, size)
      when "string-length"
        # UTF-16 units, as .NET counts
        Chars.utf16_length(args.empty? ? string_value(node) : eval_string(args[0], node, position, size)).to_f
      when "normalize-space"
        normalize_space(args.empty? ? string_value(node) : eval_string(args[0], node, position, size))
      when "translate"
        s = eval_string(args[0], node, position, size)
        from = Chars.chars(eval_string(args[1], node, position, size))
        to = Chars.chars(eval_string(args[2], node, position, size))
        map = {}
        from.each_with_index { |ch, k| map[ch] = to[k] || EMPTY unless map.key?(ch) }
        return s if map.empty?

        out = String.new(encoding: Encoding::BINARY)
        Chars.chars(s).each { |ch| out << (map.key?(ch) ? map[ch] : ch) }
        out
      when "lower-case"
        Chars.lower(eval_string(args[0], node, position, size))
      when "upper-case"
        Chars.upper(eval_string(args[0], node, position, size))
      when "not"
        !eval_bool(args[0], node, position, size)
      when "true"
        true
      when "false"
        false
      when "boolean"
        eval_bool(args[0], node, position, size)
      when "number"
        args.empty? ? string_to_number(string_value(node)) : eval_number(args[0], node, position, size)
      when "sum"
        sum = 0.0
        eval_nodes(args[0], node, position, size).each { |n| sum += string_to_number(string_value(n)) }
        sum
      when "floor"
        float_floor(eval_number(args[0], node, position, size))
      when "ceiling"
        float_ceil(eval_number(args[0], node, position, size))
      when "round"
        round(eval_number(args[0], node, position, size))
      else
        raise ArgumentError, "unknown XPath function #{e.fn}"
      end
    end

    # XPath 1.0: the chars at 1-based positions p with round(start) <= p < round(start) + round(length).
    def substring(e, node, position, size)
      args = e.args
      s = eval_string(args[0], node, position, size)
      from = round(eval_number(args[1], node, position, size))
      to = args.size > 2 ? from + round(eval_number(args[2], node, position, size)) : INF
      return EMPTY if from.nan? || to.nan?

      ascii = s.ascii_only?
      chars = ascii ? nil : Chars.chars(s)
      n = ascii ? s.bytesize : chars.size
      first = if from <= 1 then 0
              elsif from > n then n
              else from.to_i - 1
              end
      end_ = if to >= n + 1 then n
             elsif to <= 1 then 0
             else to.to_i - 1
             end
      return EMPTY if end_ <= first

      ascii ? s.byteslice(first, end_ - first) : chars[first, end_ - first].join.b
    end
  end
end
