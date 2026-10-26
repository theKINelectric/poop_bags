defmodule Subject.Gates do
  def check(x) do
    if x == :go, do: :ok, else: :err
  end

  def grade(x) do
    cond do
      x > 90 -> :a
      x > 70 -> :b
      true -> :c
    end
  end
end
