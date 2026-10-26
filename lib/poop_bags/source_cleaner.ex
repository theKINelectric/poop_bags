defmodule PoopBags.SourceCleaner do
  @moduledoc """
  Blanks out comments and string/char literals from source code while
  preserving byte offsets and newlines.

  The token analyzers then scan the cleaned text and cannot be fooled by an
  `if` inside a doc comment or braces inside a string. Everything consumed is
  replaced with spaces so keywords, braces, and newlines stay exactly where
  they were — positions in the cleaned text map 1:1 to the original.

  Patterns below use character codes (`?\\` is a backslash, `?"` a quote) to
  keep the multi-byte literals legible.
  """

  @doc "Cleans `source` for the given language (`:zig`, `:kotlin`, `:swift`, `:rust`)."
  @spec clean(binary(), :zig | :kotlin | :swift | :rust) :: binary()
  def clean(source, lang) when is_binary(source), do: code(source, lang, [])

  # ------------------------------------------------------------------ code

  defp code(<<?/, ?/, rest::binary>>, lang, acc), do: line_comment(rest, lang, [?\s, ?\s | acc])

  defp code(<<?/, ?*, rest::binary>>, lang, acc),
    do: block_comment(rest, lang, [?\s, ?\s | acc], 1)

  defp code(<<?", ?", ?", rest::binary>>, :kotlin, acc),
    do: kotlin_triple_string(rest, :kotlin, [?\s, ?\s, ?\s | acc])

  # Swift multiline strings: same """ delimiters, closed by """ (an escaped
  # \" directly before the closer stays part of the content).
  defp code(<<?", ?", ?", rest::binary>>, :swift, acc),
    do: swift_triple_string(rest, :swift, [?\s, ?\s, ?\s | acc])

  defp code(<<?", rest::binary>>, lang, acc), do: string(rest, lang, [?\s | acc], false)

  defp code(<<?#, ?", rest::binary>>, :swift, acc),
    do: swift_raw_string(rest, :swift, [?\s, ?\s | acc])

  defp code(<<?\\, ?\\, rest::binary>>, :zig, acc), do: zig_to_eol(rest, :zig, [?\s, ?\s | acc])

  # Rust raw strings: `r".."`, `r#".."#`, `r##".."##` — the close is `"` plus
  # exactly the opening count of `#`s. `br"..."` is the byte-raw variant.
  defp code(<<?r, rest::binary>>, :rust, acc) do
    case rust_raw_open(rest, 0) do
      {:ok, hashes, rest2} ->
        # the `r`, the `#`s and the `"` are all consumed by the open
        rust_raw_string(rest2, :rust, List.duplicate(?\s, hashes + 1) ++ [?\s | acc], hashes)

      :no ->
        code(rest, :rust, [?r | acc])
    end
  end

  defp code(<<?b, ?r, rest::binary>>, :rust, acc) do
    case rust_raw_open(rest, 0) do
      {:ok, hashes, rest2} ->
        rust_raw_string(rest2, :rust, List.duplicate(?\s, hashes + 1) ++ [?\s, ?\s | acc], hashes)

      :no ->
        code(<<?r, rest::binary>>, :rust, [?b | acc])
    end
  end

  # `'x'`/`'\n'`/`'}'` are char literals; `'a`, `'static`, `'out:` are
  # lifetimes/loop labels — an identifier run that does not end at a closing
  # quote stays as code.
  defp code(<<?', rest::binary>>, :rust, acc), do: rust_quote(rest, acc)

  defp code(<<?', rest::binary>>, lang, acc) when lang in [:zig, :kotlin],
    do: char_literal(rest, lang, [?\s | acc], false)

  defp code(<<c, rest::binary>>, lang, acc), do: code(rest, lang, [c | acc])
  defp code(<<>>, _lang, acc), do: done(acc)

  # -------------------------------------------------------- comments

  defp line_comment(<<c, rest::binary>>, lang, acc) when c != ?\n,
    do: line_comment(rest, lang, [?\s | acc])

  defp line_comment(<<"\n", rest::binary>>, lang, acc), do: code(rest, lang, [?\n | acc])
  defp line_comment(<<>>, _lang, acc), do: done(acc)

  # Kotlin, Swift and Rust nest block comments (/* /* */ */); Zig has no
  # block comments at all. Depth handles nesting uniformly.
  defp block_comment(<<?/, ?*, rest::binary>>, lang, acc, depth)
       when lang in [:kotlin, :swift, :rust],
       do: block_comment(rest, lang, [?\s, ?\s | acc], depth + 1)

  defp block_comment(<<?*, ?/, rest::binary>>, lang, acc, depth) do
    if depth == 1 do
      code(rest, lang, [?\s, ?\s | acc])
    else
      block_comment(rest, lang, [?\s, ?\s | acc], depth - 1)
    end
  end

  defp block_comment(<<"\n", rest::binary>>, lang, acc, depth),
    do: block_comment(rest, lang, [?\n | acc], depth)

  defp block_comment(<<_c, rest::binary>>, lang, acc, depth),
    do: block_comment(rest, lang, [?\s | acc], depth)

  defp block_comment(<<>>, _lang, acc, _depth), do: done(acc)

  # -------------------------------------------------------- double-quoted strings

  # The escape flag consumes exactly one character after a backslash —
  # including an escaped quote, so \" does not close the string. The
  # interpolation depth keeps `${ … }` (Kotlin) and `\( … )` (Swift)
  # contents inside the string: quotes within an interpolation are legal
  # and must not terminate it. A raw newline terminates an unterminated
  # string instead of swallowing the rest of the file — none of the three
  # languages allow literal newlines in single-quoted strings.
  defp string(rest, lang, acc, _escaped = false), do: string(rest, lang, acc, false, 0)

  defp string(<<_c, rest::binary>>, lang, acc, true, depth),
    do: string(rest, lang, [?\s | acc], false, depth)

  # Kotlin `${`
  defp string(<<?$, ?{, rest::binary>>, :kotlin, acc, false, 0),
    do: string(rest, :kotlin, [?\s, ?\s | acc], false, 1)

  # Swift `\(`
  defp string(<<?\\, ?(, rest::binary>>, :swift, acc, false, 0),
    do: string(rest, :swift, [?\s, ?\s | acc], false, 1)

  defp string(<<c, rest::binary>>, lang, acc, false, depth) when c == ?\\,
    do: string(rest, lang, [?\s | acc], true, depth)

  # A quote at depth 0 closes the string; inside an interpolation it is
  # just content.
  defp string(<<c, rest::binary>>, lang, acc, false, 0) when c == ?",
    do: code(rest, lang, [?\s | acc])

  defp string(<<?}, rest::binary>>, :kotlin, acc, false, depth) when depth > 0,
    do: string(rest, :kotlin, [?\s | acc], false, depth - 1)

  # Braces inside a Kotlin interpolation nest; parens inside a Swift one.
  defp string(<<?{, rest::binary>>, :kotlin, acc, false, depth) when depth > 0,
    do: string(rest, :kotlin, [?\s | acc], false, depth + 1)

  defp string(<<?(, rest::binary>>, :swift, acc, false, depth) when depth > 0,
    do: string(rest, :swift, [?\s | acc], false, depth + 1)

  defp string(<<?), rest::binary>>, :swift, acc, false, depth) when depth > 0,
    do: string(rest, :swift, [?\s | acc], false, depth - 1)

  # A raw newline inside an interpolation is legal expression formatting —
  # it only terminates an unterminated string at depth 0.
  defp string(<<"\n", rest::binary>>, lang, acc, false, depth) when depth > 0,
    do: string(rest, lang, [?\n | acc], false, depth)

  # Rust allows literal newlines inside "..." strings — content, not an
  # unterminated-string terminator. Rust has no interpolation.
  defp string(<<"\n", rest::binary>>, :rust, acc, false, depth),
    do: string(rest, :rust, [?\n | acc], false, depth)

  defp string(<<"\n", rest::binary>>, lang, acc, false, _depth),
    do: code(rest, lang, [?\n | acc])

  defp string(<<_c, rest::binary>>, lang, acc, false, depth),
    do: string(rest, lang, [?\s | acc], false, depth)

  defp string(<<>>, _lang, acc, _depth, _), do: done(acc)

  # Kotlin """triple""" strings: no escapes, can span lines, closed by """.
  defp kotlin_triple_string(<<?", ?", ?", rest::binary>>, _lang, acc),
    do: code(rest, :kotlin, [?\s, ?\s, ?\s | acc])

  defp kotlin_triple_string(<<"\n", rest::binary>>, lang, acc),
    do: kotlin_triple_string(rest, lang, [?\n | acc])

  defp kotlin_triple_string(<<_c, rest::binary>>, lang, acc),
    do: kotlin_triple_string(rest, lang, [?\s | acc])

  defp kotlin_triple_string(<<>>, _lang, acc), do: done(acc)

  # Swift #"raw" strings: no escapes, closed by "#.
  defp swift_raw_string(<<?", ?#, rest::binary>>, _lang, acc),
    do: code(rest, :swift, [?\s, ?\s | acc])

  defp swift_raw_string(<<"\n", rest::binary>>, lang, acc),
    do: swift_raw_string(rest, lang, [?\n | acc])

  defp swift_raw_string(<<_c, rest::binary>>, lang, acc),
    do: swift_raw_string(rest, lang, [?\s | acc])

  defp swift_raw_string(<<>>, _lang, acc), do: done(acc)

  defp swift_triple_string(<<?", ?", ?", rest::binary>>, _lang, acc),
    do: code(rest, :swift, [?\s, ?\s, ?\s | acc])

  defp swift_triple_string(<<?\\, ?", rest::binary>>, lang, acc),
    do: swift_triple_string(rest, lang, [?\s, ?\s | acc])

  defp swift_triple_string(<<"\n", rest::binary>>, lang, acc),
    do: swift_triple_string(rest, lang, [?\n | acc])

  defp swift_triple_string(<<_c, rest::binary>>, lang, acc),
    do: swift_triple_string(rest, lang, [?\s | acc])

  defp swift_triple_string(<<>>, _lang, acc), do: done(acc)

  # -------------------------------------------------------- char literals

  defp char_literal(<<_c, rest::binary>>, lang, acc, true),
    do: char_literal(rest, lang, [?\s | acc], false)

  defp char_literal(<<c, rest::binary>>, lang, acc, false) when c == ?\\,
    do: char_literal(rest, lang, [?\s | acc], true)

  # Unterminated quotes stop at end of line rather than swallowing code.
  defp char_literal(<<"\n", rest::binary>>, lang, acc, false),
    do: code(rest, lang, [?\n | acc])

  defp char_literal(<<c, rest::binary>>, lang, acc, false) when c == ?',
    do: code(rest, lang, [?\s | acc])

  defp char_literal(<<_c, rest::binary>>, lang, acc, false),
    do: char_literal(rest, lang, [?\s | acc], false)

  defp char_literal(<<>>, _lang, acc, _), do: done(acc)

  # -------------------------------------------------------- Zig multiline strings

  # `\\` opens a multiline literal; each following line that also begins
  # (after whitespace) with `\\` continues it.
  defp zig_to_eol(<<"\n", rest::binary>>, lang, acc) do
    {ws, rest2} = leading_ws(rest)

    case rest2 do
      <<?\\, ?\\, cont::binary>> ->
        zig_to_eol(cont, lang, [?\s, ?\s | Enum.reverse(ws) ++ [?\n | acc]])

      _ ->
        code(rest, lang, [?\n | acc])
    end
  end

  defp zig_to_eol(<<_c, rest::binary>>, lang, acc), do: zig_to_eol(rest, lang, [?\s | acc])
  defp zig_to_eol(<<>>, _lang, acc), do: done(acc)

  # -------------------------------------------------------- Rust raw strings

  # After an `r` (or `br`): count `#`s, then require `"`. Anything else means
  # the `r` is an ordinary identifier character.
  defp rust_raw_open(<<?#, rest::binary>>, n), do: rust_raw_open(rest, n + 1)
  defp rust_raw_open(<<?", rest::binary>>, n), do: {:ok, n, rest}
  defp rust_raw_open(_bin, _n), do: :no

  # Consume until `"` followed by `hashes` `#`s. A `"` with fewer is content;
  # with more, the first `hashes` close it and the extras stay as code —
  # which is also how rustc reads it.
  defp rust_raw_string(<<?", rest::binary>>, lang, acc, hashes) do
    case take_hashes(rest, hashes) do
      {:ok, rest2} -> code(rest2, lang, List.duplicate(?\s, hashes) ++ [?\s | acc])
      :no -> rust_raw_string(rest, lang, [?\s | acc], hashes)
    end
  end

  defp rust_raw_string(<<"\n", rest::binary>>, lang, acc, hashes),
    do: rust_raw_string(rest, lang, [?\n | acc], hashes)

  defp rust_raw_string(<<_c, rest::binary>>, lang, acc, hashes),
    do: rust_raw_string(rest, lang, [?\s | acc], hashes)

  defp rust_raw_string(<<>>, _lang, acc, _hashes), do: done(acc)

  defp take_hashes(<<?#, rest::binary>>, n) when n > 0, do: take_hashes(rest, n - 1)
  defp take_hashes(rest, 0), do: {:ok, rest}
  defp take_hashes(_bin, _n), do: :no

  # -------------------------------------------------------- Rust char vs lifetime

  # `'` opens a char literal only when what follows is not an identifier run
  # missing its closing quote: `'x'`, `'\n'`, `'}'` are literals, while
  # `'a`, `'static`, `'out:` are lifetimes/labels and stay visible. An
  # identifier run that DOES end at `'` is a real char literal (`'a'`) —
  # rustc reads it the same way.
  defp rust_quote(rest, acc) do
    if lifetime_ahead?(rest) do
      code(rest, :rust, [?' | acc])
    else
      char_literal(rest, :rust, [?\s | acc], false)
    end
  end

  defp lifetime_ahead?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: lifetime_run_end(rest)

  defp lifetime_ahead?(_bin), do: false

  defp lifetime_run_end(<<?', _rest::binary>>), do: false

  defp lifetime_run_end(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: lifetime_run_end(rest)

  defp lifetime_run_end(_bin), do: true

  # ---------------------------------------------------------------- helpers

  defp leading_ws(bin), do: leading_ws(bin, [])

  defp leading_ws(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: leading_ws(rest, [c | acc])
  defp leading_ws(bin, acc), do: {Enum.reverse(acc), bin}

  defp done(acc), do: IO.iodata_to_binary(Enum.reverse(acc))
end
