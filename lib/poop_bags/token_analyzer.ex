defmodule PoopBags.TokenAnalyzer do
  @moduledoc """
  Brace-tracking, token-counting complexity analyzer for Zig, Kotlin,
  Swift, and Rust — the languages we can't parse with the resident compiler.

  Method, per file:

  1. `PoopBags.SourceCleaner` blanks comments and strings (offsets preserved).
  2. Function declarations are located by regex; each one's body span is
     found by brace matching from its signature, bounded by the next
     declaration so a bodyless declaration (Swift protocol requirement,
  `    extern fn`) never borrows a neighbor's body. Kotlin expression bodies
     (`fun f() = expr`) end at the statement's end of line.
  3. Branch tokens (`if`, `while`, `case`, `&&`, switch prongs, ...) are
     matched over the whole cleaned text in one pass and each is attributed
     to the *innermost* function body containing it, so nested/local
     functions never double-count.
  4. complexity = 1 + attributed tokens.

  Policy notes (kept uniform across the token languages):

  * exhaustive choices (`switch`/`when`) count one per arm (`=>` prong,
    `->` arm, `case`/`default:`), not the keyword itself — matching how the
    Elixir analyzer counts `case` clauses;
  * Kotlin `->` after a `)` is treated as a function type (`(Int) -> Int`),
    not a `when` arm — a documented approximation;
  * Rust `=>` counts match arms and `macro_rules!` arms alike (both are
    choice arms);
  * Rust `||` counts as boolean-or only when an operand precedes it — after
    `= ( , [ { ; : > ! | &`, or after `return`/`move`/`in`, it is the
    empty-parameter closure `|| expr`. A `||` whose left operand was a
    blanked literal (`s == "x" || y` reads as `s == || y`) is a documented
    false-negative;
  * Rust `?` counts the try operator; a `?` followed by an identifier is a
    `?Sized`-style trait bound and does not count;
  * one per conditional fallback: `orelse`, `?:`, `??`.

  It is an approximation by construction — but a consistent one, which is
  exactly what a CRAP ranking needs.
  """

  alias PoopBags.Analysis.Finding
  alias PoopBags.SourceCleaner

  @fun_patterns %{
    zig: ~r/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/,
    kotlin:
      ~r/\bfun\s+(?:<(?:[^<>]|<[^<>]*>)*>\s+)?(?:[A-Za-z_][A-Za-z0-9_.]*(?:<[^<>]*>)?\.)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\s*\(/,
    swift:
      ~r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*|[=!<>+\-*/%&|^~]{1,3})\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\s*\(|(?<![\w.])init\s*[?!]?\s*\(",
    rust: ~r/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\s*\(/
  }

  # A list per language; Rust `impl` groups methods under the type they
  # implement (or the `for` target), a container the other languages fold
  # into their single pattern.
  @module_patterns %{
    zig: [
      ~r/([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:packed\s+|extern\s+)?(?:struct|union|enum|opaque)\b/
    ],
    kotlin: [~r/\b(?:class|object|interface)\s+([A-Za-z_][A-Za-z0-9_]*)/],
    swift: [~r/\b(?:class|struct|enum|extension|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/],
    rust: [
      ~r/\b(?:struct|enum|trait|union|mod)\s+([A-Za-z_][A-Za-z0-9_]*)/,
      ~r/\bimpl(?:<[^<>]*>)?\s+(?:(?:!?\s*[A-Za-z_][A-Za-z0-9_:<>]*)\s+for\s+)?([A-Za-z_][A-Za-z0-9_]*)/
    ]
  }

  # Each entry is `{label, pattern}` (labels power the explain view) or the
  # atoms `:arrow` / `:case` / `:default_colon`, which carry their own
  # statement-context exclusions.
  @branch_tokens %{
    zig: [
      {"if", ~r/\bif\b/},
      {"while", ~r/\bwhile\b/},
      {"for", ~r/\bfor\b/},
      {"catch", ~r/\bcatch\b/},
      {"orelse", ~r/\borelse\b/},
      {"and", ~r/\band\b/},
      {"or", ~r/\bor\b/},
      {"switch prong", ~r/=>/}
    ],
    kotlin: [
      {"if", ~r/\bif\b/},
      {"for", ~r/\bfor\b/},
      {"while", ~r/\bwhile\b/},
      {"catch", ~r/\bcatch\b/},
      {"&&", ~r/&&/},
      {"||", ~r/\|\|/},
      # elvis, but not `Int?::class`
      {"elvis ?:", ~r/\?:(?!:)/},
      :arrow
    ],
    swift: [
      {"if", ~r/(?<!#)\bif\b/},
      {"guard", ~r/\bguard\b/},
      {"for", ~r/\bfor\b/},
      {"while", ~r/\bwhile\b/},
      {"catch", ~r/\bcatch\b/},
      {"where", ~r/\bwhere\b/},
      :case,
      :default_colon,
      {"&&", ~r/&&/},
      {"||", ~r/\|\|/},
      {"??", ~r/\?\?/},
      # ternary `c ? a : b` — not `??`/`?.`, not an optional-type `T? =`,
      # and never crossing a newline.
      {"ternary ?:", ~r/\?(?![?.])(?!\s*=)[^\n?:]*:/}
    ],
    rust: [
      {"if", ~r/\bif\b/},
      {"for", ~r/\bfor\b/},
      {"while", ~r/\bwhile\b/},
      {"loop", ~r/\bloop\b/},
      {"match arm", ~r/=>/},
      {"try ?", ~r/\?(?![A-Za-z0-9_])/},
      {"&&", ~r/&&/},
      :rust_or
    ]
  }

  @arrow ~r/->/

  @spec analyze(binary(), :zig | :kotlin | :swift | :rust) :: [Finding.t()]
  def analyze(source, lang) do
    cleaned = SourceCleaner.clean(source, lang)

    # {pos, after_pos, name} triples in source order.
    funs =
      @fun_patterns[lang]
      |> Regex.scan(cleaned, return: :index, capture: :first)
      |> Enum.map(fn [{pos, len}] -> {pos, pos + len, fun_name(cleaned, pos, len, lang)} end)
      |> Enum.reject(fn {_pos, _after, name} -> is_nil(name) end)

    spans = spans_for(cleaned, funs, lang)
    newlines = newline_positions(cleaned) |> List.to_tuple()
    module_spans = module_spans(cleaned, lang)
    token_counts = attribute_tokens(cleaned, lang, spans)

    funs
    |> Enum.flat_map(fn {pos, _after_pos, name} = fun ->
      case Map.get(spans, fun_key(fun)) do
        nil ->
          []

        {_open, close} ->
          [
            %Finding{
              module_name: innermost_module(module_spans, pos),
              function_name: name,
              line: line_at(pos, newlines),
              end_line: line_at(close, newlines),
              complexity: 1 + Map.get(token_counts, fun_key(fun), 0)
            }
          ]
      end
    end)
    |> Enum.sort_by(&{&1.line, &1.function_name})
  end

  # ---------------------------------------------------------------- names

  defp fun_name(cleaned, pos, len, :swift) do
    binary = binary_part(cleaned, pos, len)

    case Regex.run(~r/\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)/, binary) do
      [_, name] -> name
      _ -> "init"
    end
  end

  defp fun_name(cleaned, pos, len, lang) do
    case Regex.run(@fun_patterns[lang], binary_part(cleaned, pos, len)) do
      [_, name] -> name
      _ -> nil
    end
  end

  # ---------------------------------------------------------------- spans

  defp fun_key({pos, _after_pos, name}), do: {pos, name}

  # Each function's body search is bounded by the next declaration: if the
  # opening `{` (or Kotlin `=`) is not reached before then, the declaration
  # is bodyless and gets no span.
  defp spans_for(cleaned, funs, lang) do
    size = byte_size(cleaned)

    funs
    |> Enum.zip(Enum.drop(funs, 1) ++ [nil])
    |> Enum.flat_map(fn {{_pos, after_pos, _name} = fun, next} ->
      next_start =
        case next do
          {next_pos, _, _} -> next_pos
          nil -> size
        end

      case find_body(cleaned, after_pos, min(next_start, size), lang) do
        nil -> []
        span -> [{fun_key(fun), span}]
      end
    end)
    |> Map.new()
  end

  defp find_body(cleaned, from, limit, lang) do
    scan_signature(cleaned, from, limit, byte_size(cleaned), lang, 0, 0)
  end

  # Paren/bracket depth starts at 0 even though the regex match ends AT the
  # opening `(`: that paren is never counted, so its matching `)` takes the
  # depth to -1, which is the "past the signature" level. While still inside
  # the parameter list the depth is 0 — exactly where a Kotlin default value's
  # `=` must NOT be mistaken for an expression body.
  #
  # The walk is a dispatch on the current character: depth-tracking chars
  # bump their counter, boundary candidates only act at the top level
  # (guards fail through to the catch-all, which advances), and everything
  # else advances.
  defp scan_signature(cleaned, pos, limit, size, lang, paren, bracket) when pos < limit do
    step(binary_part(cleaned, pos, 1), cleaned, pos, limit, size, lang, paren, bracket)
  end

  defp scan_signature(_cleaned, pos, limit, _size, _lang, _paren, _bracket) when pos >= limit,
    do: nil

  defp step("(", cleaned, pos, limit, size, lang, paren, bracket),
    do: scan_signature(cleaned, pos + 1, limit, size, lang, paren + 1, bracket)

  defp step(")", cleaned, pos, limit, size, lang, paren, bracket),
    do: scan_signature(cleaned, pos + 1, limit, size, lang, paren - 1, bracket)

  defp step("[", cleaned, pos, limit, size, lang, paren, bracket),
    do: scan_signature(cleaned, pos + 1, limit, size, lang, paren, bracket + 1)

  defp step("]", cleaned, pos, limit, size, lang, paren, bracket),
    do: scan_signature(cleaned, pos + 1, limit, size, lang, paren, bracket - 1)

  # Paren goes negative once the signature's own closing `)` is past;
  # brackets sit at 0 on the top level (their baseline).
  defp step("{", cleaned, pos, limit, size, lang, paren, bracket)
       when paren < 0 and bracket <= 0,
       do: body_from_open_brace(cleaned, pos, limit, size, lang, paren, bracket)

  defp step(";", _cleaned, _pos, _limit, _size, _lang, paren, bracket)
       when paren < 0 and bracket <= 0,
       do: nil

  # A closing brace before any opening one (Swift protocol requirements,
  # Kotlin interface funs) ends the declaration's scope — no body here.
  defp step("}", _cleaned, _pos, _limit, _size, _lang, paren, bracket)
       when paren < 0 and bracket <= 0,
       do: nil

  defp step("=", cleaned, pos, limit, size, :kotlin, paren, bracket)
       when paren < 0 and bracket <= 0,
       do: expression_start(cleaned, pos + 1, size, limit)

  defp step(_, cleaned, pos, limit, size, lang, paren, bracket),
    do: scan_signature(cleaned, pos + 1, limit, size, lang, paren, bracket)

  defp body_from_open_brace(cleaned, pos, limit, size, lang, paren, bracket) do
    case body_or_error_set(cleaned, pos, size, lang) do
      :error_set ->
        {_open, close} = find_close_brace(cleaned, pos + 1, size, 1, pos)
        scan_signature(cleaned, close + 1, limit, size, lang, paren, bracket)

      :body ->
        find_close_brace(cleaned, pos + 1, size, 1, pos)
    end
  end

  # A Zig return type can carry an inline error set (`fn f() error{A,B}!void
  # {`). Its braces hold only identifiers and commas and are followed by `!`
  # or the real body — skip it and keep hunting for the body.
  defp body_or_error_set(cleaned, open, size, :zig) do
    {_open, close} = find_close_brace(cleaned, open + 1, size, 1, open)
    inner = binary_part(cleaned, open + 1, max(close - open - 1, 0))

    after_close =
      cleaned
      |> binary_part(close + 1, min(size - close - 1, 2))
      |> String.trim_leading()

    if inner =~ ~r/^[A-Za-z0-9_,\s]*$/ and String.starts_with?(after_close, ["!", "{"]) do
      :error_set
    else
      :body
    end
  end

  defp body_or_error_set(_cleaned, _open, _size, _lang), do: :body

  # The expression may begin on the next line; skip whitespace to its first
  # token so the span actually contains the tokens it owns.
  defp expression_start(cleaned, pos, size, limit) do
    pos = skip_ws(cleaned, pos, size)

    expression_body_end(cleaned, pos, size, limit, pos, 0, 0, 0)
  end

  defp skip_ws(cleaned, pos, size) when pos < size do
    case binary_part(cleaned, pos, 1) do
      <<c>> when c in [?\s, ?\t, ?\n, ?\r] -> skip_ws(cleaned, pos + 1, size)
      _ -> pos
    end
  end

  defp skip_ws(_cleaned, pos, _size), do: pos

  defp find_close_brace(cleaned, pos, size, depth, open_pos) do
    if pos >= size do
      {open_pos, size}
    else
      <<c>> = binary_part(cleaned, pos, 1)

      cond do
        c == ?{ -> find_close_brace(cleaned, pos + 1, size, depth + 1, open_pos)
        c == ?} and depth == 1 -> {open_pos, pos}
        c == ?} -> find_close_brace(cleaned, pos + 1, size, depth - 1, open_pos)
        true -> find_close_brace(cleaned, pos + 1, size, depth, open_pos)
      end
    end
  end

  # Kotlin `fun f() = expr` — the body runs from after the `=` to the end of
  # the statement: the first newline after every bracket depth returns to
  # zero (EOF closes it too). Bounded by the next declaration so a runaway
  # expression can't swallow what follows.
  defp expression_body_end(cleaned, pos, size, limit, start, paren, bracket, brace)
       when pos < size do
    <<c>> = binary_part(cleaned, pos, 1)

    cond do
      c == ?( ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren + 1, bracket, brace)

      c == ?) ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren - 1, bracket, brace)

      c == ?[ ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren, bracket + 1, brace)

      c == ?] ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren, bracket - 1, brace)

      c == ?{ ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren, bracket, brace + 1)

      c == ?} ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren, bracket, brace - 1)

      c == ?\n and paren <= 0 and bracket <= 0 and brace <= 0 ->
        {start, min(pos, limit)}

      true ->
        expression_body_end(cleaned, pos + 1, size, limit, start, paren, bracket, brace)
    end
  end

  defp expression_body_end(_cleaned, pos, size, limit, start, _paren, _bracket, _brace),
    do: {start, pos |> min(size) |> min(limit)}

  # ---------------------------------------------------------------- tokens

  # One pass: every branch token is matched once and handed to the innermost
  # span containing it (max opening offset; a nested function's span always
  # opens later than its host's). One token, one owner — no per-function
  # rescans of the token list.
  defp attribute_tokens(cleaned, lang, spans) do
    span_list = Map.to_list(spans)

    @branch_tokens[lang]
    |> Enum.flat_map(fn
      :arrow -> scan(@arrow, cleaned, :arrow_filter)
      :case -> scan(~r/\bcase\b/, cleaned, :case_filter)
      :default_colon -> scan(~r/\bdefault\s*:/, cleaned, :default_colon_filter)
      :rust_or -> scan(~r/\|\|/, cleaned, :rust_or_filter)
      {_label, regex} -> scan(regex, cleaned, fn _pos -> true end)
    end)
    |> Enum.reduce(%{}, fn pos, acc ->
      case innermost_span(span_list, pos) do
        nil -> acc
        key -> Map.update(acc, key, 1, &(&1 + 1))
      end
    end)
  end

  defp innermost_span(span_list, pos) do
    span_list
    |> Enum.filter(fn {_key, {open, close}} -> pos >= open and pos < close end)
    |> Enum.max_by(fn {_key, {open, _close}} -> open end, fn -> nil end)
    |> case do
      nil -> nil
      {key, _span} -> key
    end
  end

  defp scan(regex, cleaned, filter) when is_function(filter, 1) do
    regex
    |> Regex.scan(cleaned, return: :index, capture: :first)
    |> Enum.map(fn [{pos, _len}] -> pos end)
    |> Enum.filter(filter)
  end

  defp scan(regex, cleaned, :arrow_filter) do
    scan(regex, cleaned, fn pos -> not after_close_paren?(cleaned, pos) end)
  end

  # A `case` on the heels of if/for/while/guard/catch is a pattern-match
  # clause of that statement, not an extra decision.
  defp scan(regex, cleaned, :case_filter) do
    scan(regex, cleaned, fn pos ->
      not preceded_by_word?(cleaned, pos, ~w(if for while guard catch))
    end)
  end

  # `default:` as a dictionary-lookup argument label (`dict[k, default: 0]`)
  # is not a switch arm.
  defp scan(regex, cleaned, :default_colon_filter) do
    scan(regex, cleaned, fn pos -> not preceded_by_comma?(cleaned, pos) end)
  end

  defp scan(regex, cleaned, :rust_or_filter) do
    scan(regex, cleaned, fn pos -> rust_bool_or?(cleaned, pos) end)
  end

  # `a || b` is boolean-or; a `||` right after `=`/`(`/`,`/`[`/`{`/`;`/`:`/
  # `>`/`!`/`|`/`&` or after `return`/`move`/`in` opens an empty-parameter
  # closure (`unwrap_or_else(|| ...)`), not a branch. Documented
  # false-negative: a left operand that was a blanked literal hides behind
  # the operator that preceded it (`s == "x" || y` → `s == || y` → skipped).
  defp rust_bool_or?(cleaned, pos) do
    case prev_non_space_pos(cleaned, pos - 1) do
      nil ->
        false

      p ->
        case :binary.at(cleaned, p) do
          c when c in [?=, ?(, ?,, ?[, ?{, ?;, ?:, ?>, ?!, ?|, ?&] -> false
          _ -> word_back(cleaned, p, "") not in ~w(return move in)
        end
    end
  end

  defp prev_non_space_pos(cleaned, pos) when pos >= 0 do
    case binary_part(cleaned, pos, 1) do
      <<c>> when c in [?\s, ?\t, ?\n, ?\r] -> prev_non_space_pos(cleaned, pos - 1)
      _ -> pos
    end
  end

  defp prev_non_space_pos(_cleaned, _pos), do: nil

  # `) -> Int` is a function type, not a `when` arm.
  defp after_close_paren?(cleaned, pos) do
    case previous_non_space(cleaned, pos - 1) do
      ?) -> true
      _ -> false
    end
  end

  defp preceded_by_word?(cleaned, pos, words) do
    word_back(cleaned, pos - 1, "") in words
  end

  defp word_back(_cleaned, pos, acc) when pos < 0, do: acc

  defp word_back(cleaned, pos, acc) do
    case binary_part(cleaned, pos, 1) do
      <<c>> when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ ->
        word_back(cleaned, pos - 1, <<c>> <> acc)

      _ ->
        acc
    end
  end

  defp preceded_by_comma?(cleaned, pos) do
    case previous_non_space(cleaned, pos - 1) do
      ?, -> true
      _ -> false
    end
  end

  defp previous_non_space(_cleaned, pos) when pos < 0, do: nil

  defp previous_non_space(cleaned, pos) do
    case binary_part(cleaned, pos, 1) do
      <<c>> when c in [?\s, ?\t, ?\n, ?\r] -> previous_non_space(cleaned, pos - 1)
      <<c>> -> c
    end
  end

  # ---------------------------------------------------------------- modules

  # [{start, container_end, name}] in source order. A container's reach is
  # its brace-matched body, bounded by the next declaration so a bodyless
  # declaration (`class Empty`) cannot swallow the functions that follow it;
  # a function's module is the innermost container whose span truly contains
  # it — a top-level function after `};` belongs to no one.
  defp module_spans(cleaned, lang) do
    size = byte_size(cleaned)

    matches =
      @module_patterns[lang]
      |> Enum.flat_map(fn pattern ->
        Regex.scan(pattern, cleaned, return: :index, capture: :first)
      end)
      |> Enum.map(fn [{pos, len}] -> {pos, pos + len} end)
      |> Enum.sort()

    matches
    |> Enum.zip(Enum.drop(matches, 1) ++ [nil])
    |> Enum.map(fn {{pos, match_end}, next} ->
      limit = (next && elem(next, 0)) || size
      name = module_group(binary_part(cleaned, pos, match_end - pos), lang)
      {pos, container_end(cleaned, match_end, limit, size), name}
    end)
  end

  # From the end of a declaration, find the body's opening `{` (a `;` first
  # means the declaration stands alone; parens are crossed so constructor
  # defaults like `= {}` don't fool us) and return the position just past
  # its matching close. Bounded by the next declaration.
  defp container_end(cleaned, from, limit, size) do
    case find_open_brace(cleaned, from, limit, size, 0) do
      nil ->
        from

      open ->
        {_open, close} = find_close_brace(cleaned, open + 1, size, 1, open)
        close + 1
    end
  end

  defp find_open_brace(_cleaned, pos, limit, _size, _paren) when pos >= limit, do: nil

  defp find_open_brace(cleaned, pos, limit, size, paren) do
    case binary_part(cleaned, pos, 1) do
      <<?{>> when paren == 0 -> pos
      <<?{>> -> find_open_brace(cleaned, pos + 1, limit, size, paren + 1)
      <<?}>> when paren > 0 -> find_open_brace(cleaned, pos + 1, limit, size, paren - 1)
      <<?;>> when paren == 0 -> nil
      <<?(>> -> find_open_brace(cleaned, pos + 1, limit, size, paren + 1)
      <<?)>> -> find_open_brace(cleaned, pos + 1, limit, size, paren - 1)
      _ -> find_open_brace(cleaned, pos + 1, limit, size, paren)
    end
  end

  defp innermost_module(module_spans, pos) do
    module_spans
    |> Enum.filter(fn {start, stop, _} -> start < pos and pos < stop end)
    |> Enum.max_by(fn {start, _, _} -> start end, fn -> nil end)
    |> case do
      nil -> ""
      {_start, _stop, name} -> name
    end
  end

  defp module_group(binary, lang) do
    Enum.find_value(@module_patterns[lang], "", fn pattern ->
      case Regex.run(pattern, binary) do
        [_, name] -> name
        _ -> nil
      end
    end)
  end

  # ---------------------------------------------------------------- lines

  defp newline_positions(cleaned) do
    :binary.matches(cleaned, "\n") |> Enum.map(fn {pos, _len} -> pos end)
  end

  defp line_at(pos, newlines) do
    # newlines is an ascending tuple; binary-search the count below pos.
    search(newlines, pos, 0, tuple_size(newlines)) + 1
  end

  defp search(_tuple, _value, low, high) when low >= high, do: low

  defp search(tuple, value, low, high) do
    mid = div(low + high, 2)

    if elem(tuple, mid) < value do
      search(tuple, value, mid + 1, high)
    else
      search(tuple, value, low, mid)
    end
  end

  # ---------------------------------------------------------------- explain

  @doc """
  Breakdown of one function's branch tokens, on demand (the explain view):
  `%{line: l, contributions: [{token_kind, count}]}`, or `:error` when the
  function is not in this source.
  """
  def explain(source, lang, function_name) do
    cleaned = SourceCleaner.clean(source, lang)

    funs =
      @fun_patterns[lang]
      |> Regex.scan(cleaned, return: :index, capture: :first)
      |> Enum.map(fn [{pos, len}] -> {pos, pos + len, fun_name(cleaned, pos, len, lang)} end)
      |> Enum.reject(fn {_pos, _after, name} -> is_nil(name) end)

    case Enum.find(funs, fn {_pos, _after, name} -> name == function_name end) do
      nil ->
        :error

      {pos, _after_pos, _name} = fun_entry ->
        spans = spans_for(cleaned, funs, lang)

        case Map.get(spans, fun_key(fun_entry)) do
          nil ->
            :error

          {open, close} ->
            span_list = Map.to_list(spans)

            contributions =
              @branch_tokens[lang]
              |> Enum.flat_map(fn
                :arrow ->
                  kind_counts(@arrow, cleaned, span_list, open, close, "->")

                :case ->
                  kind_counts(~r/\bcase\b/, cleaned, span_list, open, close, "case")

                :default_colon ->
                  kind_counts(~r/\bdefault\s*:/, cleaned, span_list, open, close, "default:")

                :rust_or ->
                  kind_counts(~r/\|\|/, cleaned, span_list, open, close, "||",
                    &rust_bool_or?(cleaned, &1)
                  )

                {label, regex} ->
                  kind_counts(regex, cleaned, span_list, open, close, label)
              end)
              |> Enum.sort_by(fn {_kind, n} -> -n end)

            %{
              line: line_at(pos, List.to_tuple(newline_positions(cleaned))),
              contributions: contributions
            }
        end
    end
  end

  defp kind_counts(regex, cleaned, span_list, open, close, kind),
    do: kind_counts(regex, cleaned, span_list, open, close, kind, fn _pos -> true end)

  defp kind_counts(regex, cleaned, span_list, open, close, kind, keep?) do
    regex
    |> Regex.scan(cleaned, return: :index, capture: :first)
    |> Enum.map(fn [{pos, _len}] -> pos end)
    |> Enum.filter(keep?)
    |> Enum.filter(fn pos -> pos >= open and pos < close end)
    |> Enum.reject(fn pos ->
      Enum.any?(span_list, fn {_k, {o, c}} -> o > open and pos >= o and pos < c end)
    end)
    |> length()
    |> case do
      0 -> []
      n -> [{kind, n}]
    end
  end
end
