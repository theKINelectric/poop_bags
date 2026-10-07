defmodule PoopBags.ElixirAnalyzerTest do
  use ExUnit.Case, async: true

  alias PoopBags.ElixirAnalyzer

  defp one(code) do
    {:ok, [%{complexity: cx} | _]} = ElixirAnalyzer.analyze(code)
    cx
  end

  defp names(code) do
    {:ok, findings} = ElixirAnalyzer.analyze(code)
    Map.new(findings, fn f -> {f.function_name, f.complexity} end)
  end

  test "plain function is 1" do
    assert one("defmodule T do\n  def f(x), do: x\nend\n") == 1
  end

  test "def with body false is still found" do
    assert names("defmodule T do\n  def f, do: false\nend\n") == %{"f/0" => 1}
  end

  test "if and unless add one each; else adds nothing" do
    assert one("""
           defmodule T do
             def f(x) do
               if x do
                 1
               else
                 2
               end
             end
           end
           """) == 2
  end

  test "decisions nest: if inside if, and inside if" do
    assert one("""
           defmodule T do
             def f(x) do
               if x and x do
                 if x do
                   1
                 else
                   2
                 end
               else
                 3
               end
             end
           end
           """) == 4
  end

  test "case counts arms, including decisions inside arms" do
    assert one("""
           defmodule T do
             def f(x) do
               case x do
                 1 -> if x, do: 1, else: 2
                 2 -> 3
                 _ -> 4
               end
             end
           end
           """) == 5
  end

  test "cond counts conditions" do
    assert one("""
           defmodule T do
             def f(x) do
               cond do
                 x > 1 -> 1
                 x > 0 -> 2
                 true -> 3
               end
             end
           end
           """) == 4
  end

  test "with counts steps and else arms" do
    assert one("""
           defmodule T do
             def f(x) do
               with {:ok, a} <- x,
                    {:ok, b} <- a do
                 b
               else
                 _ -> :err
               end
             end
           end
           """) == 4
  end

  test "receive counts arms and after" do
    assert one("""
           defmodule T do
           def f do
             receive do
               :a -> 1
               :b -> 2
             after
               100 -> 0
             end
           end
           end
           """) == 4
  end

  test "fn clauses past the first count, and lambda bodies count into parent" do
    # 1 + one extra fn arm + the if inside the arm = 3
    assert one("""
           defmodule T do
             def f(x) do
               g = fn
                 1 -> if x, do: 1, else: 2
                 2 -> 3
               end
               g.(1)
             end
           end
           """) == 3
  end

  test "boolean operators count, including in guards" do
    # 1 + `and` in the guard + `||` in the body
    assert names("""
           defmodule T do
             def f(x) when x > 0 and x < 9, do: x || 0
           end
           """) == %{"f/1" => 3}
  end

  test "try counts rescue/catch/else arms" do
    assert one("""
           defmodule T do
             def f(x) do
               try do
                 x
               rescue
                 e -> 1
                 other -> 2
               catch
                 :exit, _ -> 3
               else
                 _ -> 4
               end
             end
           end
           """) == 5
  end

  test "multi-clause functions are numbered" do
    {:ok, findings} =
      ElixirAnalyzer.analyze("""
      defmodule T do
        def f(1), do: 1
        def f(2), do: 2
        def f(x) when is_integer(x), do: x
      end
      """)

    assert Enum.map(findings, & &1.function_name) == ["f/1", "f/1 (clause 2)", "f/1 (clause 3)"]
  end

  test "quote blocks are pruned (generated code)" do
    assert one("""
           defmodule T do
             defmacro m do
               quote do
                 if var!(x) do
                   1
                 else
                   2
                 end
               end
             end
           end
           """) == 1
  end

  test "nested defmodules keep full names" do
    {:ok, [%{module_name: mod} | _]} =
      ElixirAnalyzer.analyze("""
      defmodule A do
        defmodule B do
          def f, do: 1
        end
      end
      """)

    assert mod == "A.B"
  end

  test "parse errors are errors, not crashes" do
    assert {:error, :parse} = ElixirAnalyzer.analyze("defmodule ,,,,")
  end

  test "parsing is atom-safe: fresh identifiers create no new atoms" do
    # 500 fresh identifiers in one file: if the parser leaked one atom per
    # identifier the count would jump by 500+. A handful of strays can come
    # from sibling async tests on the same node, hence the slack.
    unique = :erlang.unique_integer([:positive])
    atoms = for i <- 1..500, do: ":never_seen_before_#{unique}_#{i}"
    atoms_text = Enum.join(atoms, ", ")

    before_count = :erlang.system_info(:atom_count)

    {:ok, _} =
      ElixirAnalyzer.analyze("""
      defmodule T#{unique} do
        def f#{unique}, do: [#{atoms_text}]
      end
      """)

    after_count = :erlang.system_info(:atom_count)
    # Slack for sibling async tests' runtime atom noise; a real leak
    # would be ~500 (one per identifier).
    assert after_count - before_count < 200
  end

  test "top-level scripts report module as empty string" do
    {:ok, [%{module_name: mod}]} = ElixirAnalyzer.analyze("def f(x), do: x")
    assert mod == ""
  end
end
