defmodule PoopBags.ElixirAnalyzer do
  @moduledoc """
  Complexity analysis for Elixir using the real AST — the one language we
  can parse with the resident compiler.

  Parsing is atom-safe: `Code.string_to_quoted/2` normally creates a fresh
  atom for every identifier in the file, so a long-lived service scanning
  many unrelated projects would grow the atom table forever. We parse with
  `static_atoms_encoder`, then normalize the handful of structural keywords
  back to existing atoms; identifiers stay as `{:id, "name"}` tuples, which
  only affects display, never structure.

  Every `def`/`defp`/`defmacro`/`defmacrop` clause is one finding; its
  complexity is 1 plus the branch points inside the clause (guards included),
  counting:

  * `if`, `unless`                        +1
  * `cond`                                +1 per condition
  * `case`                                +1 per pattern arm
  * `with`                                +1 per `<-` step, +1 per `else` arm
  * `receive`                             +1 per match arm, +1 for `after`
  * `fn` clauses                          +1 per arm past the first; lambda
                                           bodies count into the parent
  * `and`/`or`/`&&`/`||`                  +1 each (short-circuit is a branch)
  * `try`                                 +1 per `rescue`/`catch`/`else` arm

  Nested function clauses and `quote` blocks are pruned (generated code, not
  this code) — nothing double-counts.
  """

  alias PoopBags.Analysis.Finding

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]
  @module_kinds [:defmodule, :defprotocol, :defimpl]
  @bool_ops [:and, :or, :&&, :||]

  # Reserved words that appear in the operator/keyword position and that we
  # pattern-match on. Normalized back to real (existing) atoms after the
  # atom-safe parse.
  @structural_keywords MapSet.new([
                         "def",
                         "defp",
                         "defmacro",
                         "defmacrop",
                         "defmodule",
                         "defprotocol",
                         "defimpl",
                         "if",
                         "unless",
                         "cond",
                         "case",
                         "with",
                         "receive",
                         "try",
                         "quote",
                         "fn",
                         "when"
                       ])

  @keyword_keys MapSet.new(["do", "else", "rescue", "catch", "after"])

  @spec analyze(binary()) :: {:ok, [Finding.t()]} | {:error, :parse}
  def analyze(source) when is_binary(source) do
    case Code.string_to_quoted(source,
           columns: true,
           static_atoms_encoder: fn bin, _meta -> {:ok, {:id, bin}} end
         ) do
      {:ok, ast} ->
        try do
          findings =
            ast
            |> denormalize()
            |> walk([], [])
            |> number_clauses()
            |> Enum.sort_by(& &1.line)

          {:ok, findings}
        rescue
          # Valid-but-unusual shapes (or a hostile nest deep enough to
          # overflow) fail the file, never the scan.
          _ -> {:error, :parse}
        end

      {:error, _reason} ->
        {:error, :parse}
    end
  end

  # Turn `{{:id, "def"}, meta, args}` and keyword keys `{{:id, "do"}, v}`
  # back into real atoms, so the walk below can pattern-match on them.
  # Everything identifier-shaped stays a tuple — safe and still traversable.
  defp denormalize(ast) do
    Macro.prewalk(ast, fn
      {{:id, name}, meta, args} = node when is_binary(name) ->
        if MapSet.member?(@structural_keywords, name) do
          {String.to_existing_atom(name), meta, args}
        else
          node
        end

      {{:id, name}, value} = node when is_binary(name) ->
        if MapSet.member?(@keyword_keys, name) do
          {String.to_existing_atom(name), value}
        else
          node
        end

      other ->
        other
    end)
  end

  # ---------------------------------------------------------------- walk

  # Generated code: quoted defs are not findings of *this* file.
  defp walk({:quote, _meta, _args}, _modules, acc), do: acc

  defp walk({kind, _meta, [name_node, kw]}, modules, acc)
       when kind in @module_kinds and is_list(kw) do
    case Keyword.get(kw, :do) do
      nil -> acc
      body -> walk(body, [module_name(name_node) | modules], acc)
    end
  end

  defp walk({kind, meta, [head, kw]}, modules, acc)
       when kind in @def_kinds and is_list(kw) do
    acc =
      if Keyword.has_key?(kw, :do) do
        {name, arity, guards} = head_info(head)
        body = Keyword.get(kw, :do)

        finding = %Finding{
          module_name: modules |> Enum.reverse() |> Enum.join("."),
          function_name: "#{name}/#{arity}",
          line: meta[:line] || 1,
          end_line: max_line([head | kw], meta[:line] || 1),
          complexity: 1 + complexity(body, 0) + complexity(guards, 0)
        }

        [finding | acc]
      else
        acc
      end

    # Keep walking args: nested defmodules and nested defs still get found.
    walk([head | kw], modules, acc)
  end

  defp walk({_op, _meta, args}, modules, acc) when is_list(args),
    do: walk(args, modules, acc)

  defp walk({left, right}, modules, acc),
    do: walk(right, modules, walk(left, modules, acc))

  defp walk(list, modules, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, modules, &2))

  defp walk(_node, _modules, acc), do: acc

  # ---------------------------------------------------------------- complexity

  # Branch points beneath a node. Prunes nested function clauses and quote
  # blocks — their complexity belongs to their own findings / nobody. Every
  # other counted node adds its contribution AND keeps descending, so
  # decisions inside case arms, if branches, or lambda bodies are counted.
  defp complexity({kind, _meta, _args}, acc) when kind in @def_kinds, do: acc
  defp complexity({:quote, _meta, _args}, acc), do: acc

  defp complexity({:if, _meta, args}, acc), do: complexity(args, acc + 1)
  defp complexity({:unless, _meta, args}, acc), do: complexity(args, acc + 1)

  defp complexity({:cond, _meta, [kw]}, acc) when is_list(kw),
    do: complexity(kw, acc + length(Keyword.get(kw, :do, [])))

  defp complexity({:case, _meta, [expr, kw]}, acc) when is_list(kw),
    do: complexity([expr | kw], acc + length(Keyword.get(kw, :do, [])))

  defp complexity({:receive, _meta, [kw]}, acc) when is_list(kw) do
    extra = length(Keyword.get(kw, :do, [])) + if(Keyword.has_key?(kw, :after), do: 1, else: 0)
    complexity(kw, acc + extra)
  end

  defp complexity({:with, _meta, args}, acc) when is_list(args) do
    steps = Enum.count(args, &match?({:<-, _, _}, &1))
    body = List.last(args)
    else_arms = if is_list(body), do: length(Keyword.get(body, :else, [])), else: 0
    complexity(args, acc + steps + else_arms)
  end

  defp complexity({:try, _meta, [kw]}, acc) when is_list(kw) do
    extra =
      length(Keyword.get(kw, :rescue, [])) + length(Keyword.get(kw, :catch, [])) +
        length(Keyword.get(kw, :else, []))

    complexity(kw, acc + extra)
  end

  defp complexity({:fn, _meta, clauses}, acc) when is_list(clauses),
    do: complexity(clauses, acc + max(0, length(clauses) - 1))

  defp complexity({op, _meta, [left, right]}, acc) when op in @bool_ops,
    do: complexity([left, right], acc + 1)

  defp complexity({_op, _meta, args}, acc) when is_list(args),
    do: complexity(args, acc)

  defp complexity({left, right}, acc),
    do: complexity(right, complexity(left, acc))

  defp complexity(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &complexity(&1, &2))

  defp complexity(_node, acc), do: acc

  # ---------------------------------------------------------------- helpers

  # Deepest line reached inside a clause (head + body) — its span's end.
  defp max_line({_op, meta, args}, acc) when is_list(args),
    do: max_line(args, max(acc, meta[:line] || acc))

  defp max_line({left, right}, acc), do: max_line(right, max_line(left, acc))

  defp max_line(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &max_line(&1, &2))

  defp max_line(_node, acc), do: acc

  # Returns {name, arity, guard_node}. `nil` guard means none.
  defp head_info({:when, _meta, [inner | guards]}),
    do: put_elem(head_info(inner), 2, guards)

  defp head_info({name, _meta, args}) when is_list(args),
    do: {name_text(name), length(args), nil}

  defp head_info({name, _meta, nil}), do: {name_text(name), 0, nil}
  defp head_info(_other), do: {"unknown", 0, nil}

  defp name_text({:id, name}) when is_binary(name), do: name
  defp name_text(name) when is_atom(name), do: Atom.to_string(name)
  defp name_text(other), do: inspect(other)

  defp module_name({:__aliases__, _meta, parts}),
    do: parts |> Enum.map(&name_text/1) |> Enum.join(".")

  defp module_name({:id, name}) when is_binary(name), do: name
  defp module_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp module_name(_), do: "?"

  # Multi-clause functions get a "(clause n)" suffix so every clause stays
  # visible in the ranking.
  defp number_clauses(findings) do
    findings
    |> Enum.group_by(&{&1.module_name, &1.function_name})
    |> Enum.flat_map(fn {_key, group} ->
      group
      |> Enum.sort_by(& &1.line)
      |> Enum.with_index(1)
      |> Enum.map(fn {%Finding{} = finding, index} ->
        if index == 1,
          do: finding,
          else: %Finding{finding | function_name: finding.function_name <> " (clause #{index})"}
      end)
    end)
  end

  # ---------------------------------------------------------------- explain

  @doc """
  Breakdown of one named function's branch points, on demand (the explain
  view): `[{construct, count}]` summed across its clauses. `base_name` is the
  `f/2` form (clause suffixes ignored).
  """
  def explain(source, base_name) do
    case Code.string_to_quoted(source,
           columns: true,
           static_atoms_encoder: fn bin, _meta -> {:ok, {:id, bin}} end
         ) do
      {:ok, ast} ->
        ast
        |> denormalize()
        |> collect_reasons(base_name, [])
        |> case do
          [] -> :error
          reasons -> reasons |> Enum.sort_by(fn {_k, n} -> -n end)
        end

      {:error, _} ->
        :error
    end
  end

  defp collect_reasons({kind, _meta, [head, kw]}, base_name, acc)
       when kind in @def_kinds and is_list(kw) do
    {name, arity, guards} = head_info(head)

    acc =
      if "#{name}/#{arity}" == base_name and Keyword.has_key?(kw, :do) do
        body = Keyword.get(kw, :do)
        reasons(body, reasons(guards, []))
      else
        []
      end ++ acc

    collect_reasons([head | kw], base_name, acc)
  end

  defp collect_reasons({_op, _meta, args}, base_name, acc) when is_list(args),
    do: collect_reasons(args, base_name, acc)

  defp collect_reasons({left, right}, base_name, acc),
    do: collect_reasons(right, base_name, collect_reasons(left, base_name, acc))

  defp collect_reasons(list, base_name, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_reasons(&1, base_name, &2))

  defp collect_reasons(_node, _base_name, acc), do: acc

  # Like complexity/2, but every counted node also records its reason.
  defp reasons({kind, _meta, _args}, acc) when kind in @def_kinds, do: acc
  defp reasons({:quote, _meta, _args}, acc), do: acc

  defp reasons({:if, _meta, args}, acc), do: reasons(args, count("if", acc))
  defp reasons({:unless, _meta, args}, acc), do: reasons(args, count("unless", acc))

  defp reasons({:cond, _meta, [kw]}, acc) when is_list(kw),
    do: reasons(kw, count_n("cond condition", length(Keyword.get(kw, :do, [])), acc))

  defp reasons({:case, _meta, [expr, kw]}, acc) when is_list(kw),
    do: reasons([expr | kw], count_n("case arm", length(Keyword.get(kw, :do, [])), acc))

  defp reasons({:receive, _meta, [kw]}, acc) when is_list(kw) do
    n = length(Keyword.get(kw, :do, [])) + if(Keyword.has_key?(kw, :after), do: 1, else: 0)
    reasons(kw, count_n("receive arm", n, acc))
  end

  defp reasons({:with, _meta, args}, acc) when is_list(args) do
    steps = Enum.count(args, &match?({:<-, _, _}, &1))
    body = List.last(args)
    elses = if is_list(body), do: length(Keyword.get(body, :else, [])), else: 0

    args
    |> reasons(count_n("with step", steps, acc))
    |> count_n("with else", elses)
  end

  defp reasons({:try, _meta, [kw]}, acc) when is_list(kw) do
    n =
      length(Keyword.get(kw, :rescue, [])) + length(Keyword.get(kw, :catch, [])) +
        length(Keyword.get(kw, :else, []))

    kw
    |> reasons(acc)
    |> count_n("try arm", n)
  end

  defp reasons({:fn, _meta, clauses}, acc) when is_list(clauses),
    do: clauses |> reasons(count_n("fn arm", max(0, length(clauses) - 1), acc))

  defp reasons({op, _meta, [l, r]}, acc) when op in @bool_ops,
    do: reasons([l, r], count("boolean op", acc))

  defp reasons({_op, _meta, args}, acc) when is_list(args), do: reasons(args, acc)

  defp reasons({left, right}, acc), do: reasons(right, reasons(left, acc))

  defp reasons(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &reasons(&1, &2))

  defp reasons(_node, acc), do: acc

  defp count(kind, acc), do: count_n(kind, 1, acc)

  defp count_n(_kind, 0, acc), do: acc

  defp count_n(kind, n, acc) do
    index = Enum.find_index(acc, fn {k, _} -> k == kind end)

    if index do
      List.update_at(acc, index, fn {k, v} -> {k, v + n} end)
    else
      [{kind, n} | acc]
    end
  end
end
