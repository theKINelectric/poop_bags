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

  @doc "Cleans `source` for the given language (`:zig`, `:kotlin`, `:swift`)."
  @spec clean(binary(), :zig | :kotlin | :swift) :: binary()
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

  defp code(<<?', rest::binary>>, lang, acc) when lang in [:zig, :kotlin],
    do: char_literal(rest, lang, [?\s | acc], false)

  defp code(<<c, rest::binary>>, lang, acc), do: code(rest, lang, [c | acc])
  defp code(<<>>, _lang, acc), do: done(acc)

  # -------------------------------------------------------- comments

  defp line_comment(<<c, rest::binary>>, lang, acc) when c != ?\n,
    do: line_comment(rest, lang, [?\s | acc])

  defp line_comment(<<"\n", rest::binary>>, lang, acc), do: code(rest, lang, [?\n | acc])
  defp line_comment(<<>>, _lang, acc), do: done(acc)

  # Kotlin and Swift nest block comments (/* /* */ */); Zig has no block
  # comments at all. Depth handles nesting uniformly.
  defp block_comment(<<?/, ?*, rest::binary>>, lang, acc, depth) when lang in [:kotlin, :swift],
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

  # ---------------------------------------------------------------- helpers

  defp leading_ws(bin), do: leading_ws(bin, [])

  defp leading_ws(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: leading_ws(rest, [c | acc])
  defp leading_ws(bin, acc), do: {Enum.reverse(acc), bin}

  defp done(acc), do: IO.iodata_to_binary(Enum.reverse(acc))
end
