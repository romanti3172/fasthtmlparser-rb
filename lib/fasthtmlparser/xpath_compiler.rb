# frozen_string_literal: true

module FastHtmlParser
  # @api private The tokenizer and parser of XPath 1.0 expressions (section 3 of the spec). Positions in error
  # messages are in chars.
  class XPathCompiler
    T_END = 0
    T_SLASH = 1
    T_DOUBLE_SLASH = 2
    T_LPAREN = 3
    T_RPAREN = 4
    T_LBRACKET = 5
    T_RBRACKET = 6
    T_DOT = 7
    T_DOT_DOT = 8
    T_AT = 9
    T_COMMA = 10
    T_COLON_COLON = 11
    T_PIPE = 12
    T_PLUS = 13
    T_MINUS = 14
    T_EQ = 15
    T_NEQ = 16
    T_LT = 17
    T_LE = 18
    T_GT = 19
    T_GE = 20
    T_STAR = 21 # name test *
    T_MULTIPLY = 22 # operator *
    T_AND = 23
    T_OR = 24
    T_DIV = 25
    T_MOD = 26
    T_NAME = 27
    T_LITERAL = 28
    T_NUMBER = 29
    T_DOLLAR = 30

    X = XPathQuery

    Token = Struct.new(:k, :t, :n, :p)

    SINGLE = { "(" => T_LPAREN, ")" => T_RPAREN, "[" => T_LBRACKET, "]" => T_RBRACKET, "@" => T_AT, "," => T_COMMA,
               "|" => T_PIPE, "+" => T_PLUS, "-" => T_MINUS, "=" => T_EQ, "$" => T_DOLLAR }.freeze

    NODE_TYPES = { "node" => true, "text" => true, "comment" => true, "processing-instruction" => true }.freeze
    OPERATORS = { "and" => T_AND, "or" => T_OR, "div" => T_DIV, "mod" => T_MOD }.freeze
    OPERAND_ENDS = [T_RPAREN, T_RBRACKET, T_DOT, T_DOT_DOT, T_STAR, T_NAME, T_LITERAL, T_NUMBER].freeze
    AXES = {
      "child" => X::AXIS_CHILD,
      "descendant" => X::AXIS_DESCENDANT,
      "descendant-or-self" => X::AXIS_DESCENDANT_OR_SELF,
      "self" => X::AXIS_SELF,
      "parent" => X::AXIS_PARENT,
      "ancestor" => X::AXIS_ANCESTOR,
      "ancestor-or-self" => X::AXIS_ANCESTOR_OR_SELF,
      "following-sibling" => X::AXIS_FOLLOWING_SIBLING,
      "preceding-sibling" => X::AXIS_PRECEDING_SIBLING,
      "following" => X::AXIS_FOLLOWING,
      "preceding" => X::AXIS_PRECEDING,
      "attribute" => X::AXIS_ATTRIBUTE
    }.freeze

    MANY = 1 << 30

    # name => [min args, max args, type]
    FUNCTIONS = {
      "last" => [0, 0, X::TYPE_NUMBER],
      "position" => [0, 0, X::TYPE_NUMBER],
      "count" => [1, 1, X::TYPE_NUMBER],
      "name" => [0, 1, X::TYPE_STRING],
      "local-name" => [0, 1, X::TYPE_STRING],
      "string" => [0, 1, X::TYPE_STRING],
      "concat" => [2, MANY, X::TYPE_STRING],
      "starts-with" => [2, 2, X::TYPE_BOOLEAN],
      "ends-with" => [2, 2, X::TYPE_BOOLEAN],
      "contains" => [2, 2, X::TYPE_BOOLEAN],
      "substring-before" => [2, 2, X::TYPE_STRING],
      "substring-after" => [2, 2, X::TYPE_STRING],
      "substring" => [2, 3, X::TYPE_STRING],
      "string-length" => [0, 1, X::TYPE_NUMBER],
      "normalize-space" => [0, 1, X::TYPE_STRING],
      "translate" => [3, 3, X::TYPE_STRING],
      "lower-case" => [1, 1, X::TYPE_STRING],
      "upper-case" => [1, 1, X::TYPE_STRING],
      "not" => [1, 1, X::TYPE_BOOLEAN],
      "true" => [0, 0, X::TYPE_BOOLEAN],
      "false" => [0, 0, X::TYPE_BOOLEAN],
      "boolean" => [1, 1, X::TYPE_BOOLEAN],
      "number" => [0, 1, X::TYPE_NUMBER],
      "sum" => [1, 1, X::TYPE_NUMBER],
      "floor" => [1, 1, X::TYPE_NUMBER],
      "ceiling" => [1, 1, X::TYPE_NUMBER],
      "round" => [1, 1, X::TYPE_NUMBER]
    }.freeze

    LETTER = /\A\p{L}\z/
    LETTER_OR_DIGIT = /\A[\p{L}\p{Nd}]\z/

    def initialize(expression)
      @expression = expression
      unless expression.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise XPathError, "invalid XPath #{Chars.quote(expression)}: not UTF-8"
      end

      @source = Chars.chars(expression)
      @tokens = []
      @index = 0
      tokenize
    end

    # The compiled expression.
    def parse
      expr = parse_expr
      fail!("unexpected #{describe(peek(0))}") if peek(0).k != T_END
      expr
    end

    private

    def fail_at!(msg, position)
      raise XPathError, "invalid XPath #{Chars.quote(@expression)} at position #{position}: #{msg}"
    end

    def fail!(msg)
      fail_at!(msg, peek(0).p)
    end

    def text(from, to)
      @source[from...to].join
    end

    def utf8(ch)
      ch.dup.force_encoding(Encoding::UTF_8)
    end

    def letter?(ch)
      return Chars.alpha_byte?(ch.getbyte(0)) if ch.bytesize == 1

      LETTER.match?(utf8(ch))
    end

    def xname_start?(ch)
      ch == "_" || letter?(ch)
    end

    def xname_char?(ch)
      if ch.bytesize == 1
        c = ch.getbyte(0)
        return Chars.alpha_byte?(c) || Chars.digit_byte?(c) || c == 95 || c == 45 || c == 46
      end
      LETTER_OR_DIGIT.match?(utf8(ch))
    end

    def digit?(ch)
      !ch.nil? && ch.bytesize == 1 && Chars.digit_byte?(ch.getbyte(0))
    end

    def space?(ch)
      Chars.space_at(ch, 0, ch.bytesize) == ch.bytesize
    end

    def tokenize
      s = @source
      n = s.size
      i = 0
      loop do
        i += 1 while i < n && space?(s[i])
        if i >= n
          @tokens << Token.new(T_END, Chars::EMPTY, 0.0, i)
          return
        end
        start = i
        ch = s[i]
        nxt = s[i + 1]

        # XPath 1.0 lexical rule: after a token that can end an operand, '*' and and/or/div/mod are operators
        operator_expected = !@tokens.empty? && OPERAND_ENDS.include?(@tokens[-1].k)

        kind = T_END
        txt = Chars::EMPTY
        number = 0.0
        if ch == "/"
          if nxt == "/"
            kind = T_DOUBLE_SLASH
            i += 2
          else
            kind = T_SLASH
            i += 1
          end
        elsif SINGLE.key?(ch)
          kind = SINGLE[ch]
          i += 1
        elsif ch == "*"
          kind = operator_expected ? T_MULTIPLY : T_STAR
          i += 1
        elsif ch == "!"
          fail_at!("'!' must be followed by '='", i) if nxt != "="
          kind = T_NEQ
          i += 2
        elsif ch == "<" || ch == ">"
          if nxt == "="
            kind = ch == "<" ? T_LE : T_GE
            i += 2
          else
            kind = ch == "<" ? T_LT : T_GT
            i += 1
          end
        elsif ch == ":"
          fail_at!("unexpected ':'", i) if nxt != ":"
          kind = T_COLON_COLON
          i += 2
        elsif ch == '"' || ch == "'"
          stop = ((i + 1)...n).find { |k| s[k] == ch }
          fail_at!("unterminated string literal", i) if stop.nil?
          kind = T_LITERAL
          txt = text(i + 1, stop).freeze
          i = stop + 1
        elsif ch == "." && nxt == "."
          kind = T_DOT_DOT
          i += 2
        elsif ch == "." && !digit?(nxt)
          kind = T_DOT
          i += 1
        elsif digit?(ch) || ch == "."
          i += 1 while i < n && digit?(s[i])
          if i < n && s[i] == "."
            i += 1
            i += 1 while i < n && digit?(s[i])
          end
          kind = T_NUMBER
          number = text(start, i).to_f
        elsif xname_start?(ch)
          i += 1
          while i < n
            if xname_char?(s[i])
              i += 1
            elsif s[i] == ":" && i + 1 < n && s[i + 1] != ":" && (xname_start?(s[i + 1]) || s[i + 1] == "*")
              # a prefixed name (dc:creator) or prefix:*
              i += 2
              break if s[i - 1] == "*"
            else
              break
            end
          end
          kind = T_NAME
          txt = text(start, i).freeze
          if operator_expected
            op = OPERATORS[txt]
            fail_at!("expected an operator, found '#{Chars.u(txt.dup)}'", start) if op.nil?
            kind = op
          end
        else
          fail_at!("unexpected character '#{Chars.u(ch.dup)}'", i)
        end
        @tokens << Token.new(kind, txt, number, start)
      end
    end

    # ----- parser helpers -----

    def peek(offset)
      i = @index + offset
      @tokens[i < @tokens.size ? i : @tokens.size - 1]
    end

    def advance
      t = @tokens[@index]
      @index += 1
      t
    end

    def accept(kind)
      return false if peek(0).k != kind

      @index += 1
      true
    end

    def expect(kind, what)
      fail!("expected #{what}, found #{describe(peek(0))}") unless accept(kind)
    end

    def describe(t)
      case t.k
      when T_END then "the end of the expression"
      when T_NAME, T_LITERAL then "'#{Chars.u(t.t.dup)}'"
      when T_NUMBER then X.number_to_string(t.n)
      else
        to = [@source.size, t.p + 2].min
        "'#{Chars.u(text(t.p, to).rstrip)}'"
      end
    end

    # ----- expressions -----

    def expr(op, type, pos, **fields)
      X::Expr.new(op: op, type: type, pos: pos, **fields)
    end

    def positional?(e)
      e.type == X::TYPE_NUMBER || e.pos
    end

    def step(axis, test, preds = [])
      X::Step.new(axis, test, preds.freeze, preds.any? { |p| positional?(p) }).freeze
    end

    def node_test(kind, name = Chars::EMPTY)
      X::NodeTest.new(kind, name, kind == X::TK_NAME ? Query.by(name) : nil).freeze
    end

    # Whether the expression is a bare @name (one attribute step, no predicates); its name (lower case), or nil.
    def attribute_name(e)
      return nil if e.op != X::E_PATH || !e.start.nil? || e.absolute || e.steps.size != 1

      s = e.steps[0]
      return nil if s.axis != X::AXIS_ATTRIBUTE || !s.preds.empty? || s.test.k != X::TK_NAME

      s.test.name.downcase(:ascii).freeze
    end

    # @name = 'literal' is compared in place; everything else by the general rules.
    def make_equality(op, left, right)
      l = attribute_name(left)
      if l && right.op == X::E_LITERAL
        return expr(X::E_ATTR_EQUALS, X::TYPE_BOOLEAN, false, name: l, value: right.value, negate: op == X::OP_NEQ)
      end

      r = attribute_name(right)
      if r && left.op == X::E_LITERAL
        return expr(X::E_ATTR_EQUALS, X::TYPE_BOOLEAN, false, name: r, value: left.value, negate: op == X::OP_NEQ)
      end

      compare_expr(op, left, right)
    end

    def compare_expr(op, left, right)
      expr(X::E_COMPARE, X::TYPE_BOOLEAN, left.pos || right.pos, cmp: op, l: left, r: right)
    end

    def arith(op, left, right)
      expr(X::E_ARITH, X::TYPE_NUMBER, left.pos || right.pos, arith: op, l: left, r: right)
    end

    # //x is descendant-or-self::node()/child::x. Without positional predicates on x it is the same as
    # descendant::x: one linear scan of the tag list instead of the children of every node.
    def optimize(steps)
      steps = steps.dup
      i = 0
      while i < steps.size - 1
        s = steps[i]
        if s.axis == X::AXIS_DESCENDANT_OR_SELF && s.test.equal?(X::ANY_NODE_TEST) && s.preds.empty?
          nxt = steps[i + 1]
          if nxt.axis == X::AXIS_CHILD && !nxt.positional
            steps[i] = step(X::AXIS_DESCENDANT, nxt.test, nxt.preds)
            steps.delete_at(i + 1)
          elsif nxt.axis == X::AXIS_CHILD || nxt.axis == X::AXIS_ATTRIBUTE
            # only the root and elements have children or attributes: skip the text nodes
            steps[i] = step(X::AXIS_DESCENDANT_OR_SELF, X::CONTAINERS_TEST)
          end
        end
        i += 1
      end
      steps.freeze
    end

    def can_start_step?(t)
      k = t.k
      k == T_DOT || k == T_DOT_DOT || k == T_AT || k == T_STAR || k == T_NAME
    end

    # ----- grammar (XPath 1.0, section 3) -----

    def parse_expr
      parse_or
    end

    def parse_or
      left = parse_and
      while accept(T_OR)
        right = parse_and
        left = expr(X::E_OR, X::TYPE_BOOLEAN, left.pos || right.pos, l: left, r: right)
      end
      left
    end

    def parse_and
      left = parse_equality
      while accept(T_AND)
        right = parse_equality
        left = expr(X::E_AND, X::TYPE_BOOLEAN, left.pos || right.pos, l: left, r: right)
      end
      left
    end

    def parse_equality
      left = parse_relational
      loop do
        if accept(T_EQ)
          op = X::OP_EQ
        elsif accept(T_NEQ)
          op = X::OP_NEQ
        else
          return left
        end
        left = make_equality(op, left, parse_relational)
      end
    end

    def parse_relational
      left = parse_additive
      loop do
        if accept(T_LT)
          op = X::OP_LT
        elsif accept(T_LE)
          op = X::OP_LE
        elsif accept(T_GT)
          op = X::OP_GT
        elsif accept(T_GE)
          op = X::OP_GE
        else
          return left
        end
        left = compare_expr(op, left, parse_additive)
      end
    end

    def parse_additive
      left = parse_multiplicative
      loop do
        if accept(T_PLUS)
          left = arith(X::ARITH_ADD, left, parse_multiplicative)
        elsif accept(T_MINUS)
          left = arith(X::ARITH_SUB, left, parse_multiplicative)
        else
          return left
        end
      end
    end

    def parse_multiplicative
      left = parse_unary
      loop do
        if accept(T_MULTIPLY)
          left = arith(X::ARITH_MUL, left, parse_unary)
        elsif accept(T_DIV)
          left = arith(X::ARITH_DIV, left, parse_unary)
        elsif accept(T_MOD)
          left = arith(X::ARITH_MOD, left, parse_unary)
        else
          return left
        end
      end
    end

    def parse_unary
      if accept(T_MINUS)
        operand = parse_unary
        return expr(X::E_NEGATE, X::TYPE_NUMBER, operand.pos, e: operand)
      end
      parse_union
    end

    def parse_union
      left = parse_path
      while peek(0).k == T_PIPE
        position = advance.p
        right = parse_path
        if left.type != X::TYPE_NODE_SET || right.type != X::TYPE_NODE_SET
          fail_at!("'|' needs node-sets on both sides", position)
        end
        left = expr(X::E_UNION, X::TYPE_NODE_SET, left.pos || right.pos, l: left, r: right)
      end
      left
    end

    def parse_path
      t = peek(0)
      is_filter = t.k == T_LITERAL || t.k == T_NUMBER || t.k == T_LPAREN || t.k == T_DOLLAR ||
                  (t.k == T_NAME && peek(1).k == T_LPAREN && !NODE_TYPES.key?(t.t))
      return parse_location_path unless is_filter

      position = t.p
      primary = parse_primary
      predicates = parse_predicates
      unless predicates.empty?
        fail_at!("a predicate needs a node-set", position) if primary.type != X::TYPE_NODE_SET
        primary = expr(X::E_FILTER, X::TYPE_NODE_SET, primary.pos, primary: primary, preds: predicates.freeze)
      end
      k = peek(0).k
      return primary if k != T_SLASH && k != T_DOUBLE_SLASH

      fail_at!("'/' needs a node-set on the left", position) if primary.type != X::TYPE_NODE_SET
      steps = optimize(parse_relative_steps([], true))
      expr(X::E_PATH, X::TYPE_NODE_SET, primary.pos, start: primary, absolute: false, steps: steps)
    end

    def parse_location_path
      steps = []
      absolute = false
      if accept(T_SLASH)
        absolute = true
        steps = parse_relative_steps(steps, false) if can_start_step?(peek(0))
      elsif peek(0).k == T_DOUBLE_SLASH
        absolute = true
        steps = parse_relative_steps(steps, true)
      else
        fail!("unexpected #{describe(peek(0))}") unless can_start_step?(peek(0))
        steps = parse_relative_steps(steps, false)
      end
      path = expr(X::E_PATH, X::TYPE_NODE_SET, false, start: nil, absolute: absolute, steps: optimize(steps))
      name = attribute_name(path)
      path.attr = name if name # read in place where a string is needed
      path
    end

    # Steps separated by '/' or '//'; after_slash: the next token is a '/' or '//' to read first.
    def parse_relative_steps(steps, after_slash)
      steps << parse_step unless after_slash
      loop do
        if accept(T_SLASH)
          steps << parse_step
        elsif accept(T_DOUBLE_SLASH)
          steps << step(X::AXIS_DESCENDANT_OR_SELF, X::ANY_NODE_TEST)
          steps << parse_step
        else
          return steps
        end
      end
    end

    def parse_step
      return step(X::AXIS_SELF, X::ANY_NODE_TEST) if accept(T_DOT)
      return step(X::AXIS_PARENT, X::ANY_NODE_TEST) if accept(T_DOT_DOT)

      axis = X::AXIS_CHILD
      if accept(T_AT)
        axis = X::AXIS_ATTRIBUTE
      elsif peek(0).k == T_NAME && peek(1).k == T_COLON_COLON
        name = advance
        a = AXES[name.t]
        if a.nil?
          fail_at!("the namespace axis is not supported", name.p) if name.t == "namespace"
          fail_at!("unknown axis '#{Chars.u(name.t.dup)}'", name.p)
        end
        axis = a
        advance
      end
      test = parse_node_test
      step(axis, test, parse_predicates)
    end

    def parse_node_test
      return node_test(X::TK_WILDCARD) if accept(T_STAR)

      t = peek(0)
      fail!("expected a node test, found #{describe(t)}") if t.k != T_NAME
      advance
      name = t.t
      if peek(0).k == T_LPAREN && NODE_TYPES.key?(name)
        advance
        accept(T_LITERAL) if name == "processing-instruction"
        expect(T_RPAREN, "')'")
        return case name
               when "node" then X::ANY_NODE_TEST
               when "text" then node_test(X::TK_TEXT)
               when "comment" then node_test(X::TK_COMMENT)
               else node_test(X::TK_PI)
               end
      end
      return node_test(X::TK_PREFIX, name.byteslice(0, name.bytesize - 1).freeze) if name.end_with?(":*")

      node_test(X::TK_NAME, name)
    end

    def parse_predicates
      predicates = []
      while accept(T_LBRACKET)
        p = parse_expr
        expect(T_RBRACKET, "']'")
        # [@name]: an existence check instead of a node-set
        name = attribute_name(p)
        p = expr(X::E_ATTR_EXISTS, X::TYPE_BOOLEAN, false, name: name) if name
        predicates << p
      end
      predicates
    end

    def parse_primary
      t = advance
      case t.k
      when T_LITERAL
        return expr(X::E_LITERAL, X::TYPE_STRING, false, value: t.t)
      when T_NUMBER
        return expr(X::E_NUMBER, X::TYPE_NUMBER, false, value: t.n)
      when T_LPAREN
        e = parse_expr
        expect(T_RPAREN, "')'")
        return e
      when T_DOLLAR
        fail_at!("variables are not supported", t.p)
      end

      # function call
      info = FUNCTIONS[t.t]
      fail_at!("unknown function '#{Chars.u(t.t.dup)}()'", t.p) if info.nil?
      expect(T_LPAREN, "'('")
      args = []
      unless accept(T_RPAREN)
        loop do
          args << parse_expr
          break unless accept(T_COMMA)
        end
        expect(T_RPAREN, "')'")
      end
      fn = t.t
      fail_at!("wrong number of arguments for #{fn}()", t.p) if args.size < info[0] || args.size > info[1]
      needs_node_set = fn == "count" || fn == "sum" || fn == "name" || fn == "local-name"
      if needs_node_set && !args.empty? && args[0].type != X::TYPE_NODE_SET
        fail_at!("#{fn}() needs a node-set argument", t.p)
      end
      pos = fn == "position" || fn == "last" || args.any?(&:pos)
      attribute_test(fn, args) || expr(X::E_FUNCTION, info[2], pos, fn: fn, args: args.freeze)
    end

    # contains(@a, 'x'), starts-with(...), ends-with(...), also with the attribute wrapped in literals
    # (contains(concat(' ', @class, ' '), ' x '), the usual class test), are evaluated on the attribute in place,
    # without a node-set for every element. nil: a plain function call.
    def attribute_test(fn, args)
      return nil unless %w[contains starts-with ends-with].include?(fn) && args[1].op == X::E_LITERAL

      arg = args[0]
      name = attribute_name(arg)
      prefix = suffix = EMPTY_BINARY
      if name.nil?
        return nil unless arg.op == X::E_FUNCTION && arg.fn == "concat" && arg.args.size == 3 &&
                          arg.args[0].op == X::E_LITERAL && arg.args[2].op == X::E_LITERAL

        name = attribute_name(arg.args[1])
        return nil if name.nil?

        prefix = arg.args[0].value.b.freeze
        suffix = arg.args[2].value.b.freeze
      end
      expr(X::E_ATTR_TEST, X::TYPE_BOOLEAN, false, fn: fn, l: prefix, name: name, r: suffix,
                                                   value: args[1].value.b.freeze)
    end

    EMPTY_BINARY = "".b.freeze
    private_constant :EMPTY_BINARY
  end
end
