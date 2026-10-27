defmodule PoopBags.Diff do
  @moduledoc """
  Scan-to-scan comparison: did the refactor actually clean anything up?

  Findings are matched by **stable identity** — language + project-relative
  path + module + function name with Elixir's `(clause n)` suffixes stripped
  — never by line numbers. For an identity present in both scans, the
  compared metric is the worst CRAP among its clauses.

  Outcomes (per identity):

  * `introduced` — only in the new scan (a violation when above threshold)
  * `removed`    — only in the baseline
  * `regressed`  — matched, CRAP rose
  * `improved`   — matched, CRAP fell
  * `resolved`   — matched, was a violation in the baseline and no longer is
  * `unchanged`  — matched, same CRAP

  Excluded, failed, or newly-unmeasured code never counts as resolved: an
  identity missing from the new scan is `removed`, full stop, and the guard
  section flags anything that makes the two scans incomparable (different
  projects, analyzer policies, or exclusion sets).
  """

  alias PoopBags.Catalog
  alias PoopBags.Catalog.Finding
  alias PoopBags.Catalog.Scan

  defstruct baseline: nil,
            current: nil,
            threshold: 20.0,
            comparable: true,
            warnings: [],
            rows: [],
            gate_failure_rows: [],
            summary: %{}

  @outcomes ~w(introduced removed regressed improved resolved unchanged)a

  @doc """
  Diffs `current` (the newer scan) against `baseline`.

  Options: `:limit` (maximum display rows, default 200). The CI gate evaluates
  every identity independently of this display limit; `:outcome` filtering
  happens in the caller.
  """
  @spec between(Scan.t(), Scan.t(), keyword()) :: %__MODULE__{}
  def between(%Scan{} = baseline, %Scan{} = current, opts \\ []) do
    threshold = current.threshold || 20.0
    limit = Keyword.get(opts, :limit, 200)

    warnings =
      []
      |> warn_unless(
        fn -> (baseline.files_failed || 0) == 0 and (current.files_failed || 0) == 0 end,
        "one or both scans contain failed files; partial findings cannot establish a clean comparison"
      )
      |> warn_unless(
        fn -> baseline.project_path == current.project_path end,
        "scans cover different projects"
      )
      |> warn_unless(
        fn ->
          policy_of(baseline) == policy_of(current) and policy_of(baseline) != nil
        end,
        "analyzer policies differ — counts may not be comparable"
      )
      |> warn_unless(
        fn -> exclusions_of(baseline) == exclusions_of(current) end,
        "exclusion sets differ — code may count as removed merely because it was excluded"
      )
      |> warn_unless(
        fn -> not DateTime.after?(baseline.inserted_at, current.inserted_at) end,
        "baseline is newer than the comparison scan"
      )

    baseline_groups = group(Catalog.all_findings(baseline))
    current_groups = group(Catalog.all_findings(current))

    identities =
      (Map.keys(baseline_groups) ++ Map.keys(current_groups))
      |> Enum.uniq()

    {rows, summary} =
      Enum.reduce(identities, {[], %{}}, fn identity, {rows, summary} ->
        case {baseline_groups[identity], current_groups[identity]} do
          {nil, current_findings} ->
            {row, kind} = row_for_new(identity, current_findings, threshold)
            {[row | rows], Map.update(summary, kind, 1, &(&1 + 1))}

          {baseline_findings, nil} ->
            old = worst(baseline_findings)

            row = %{
              identity: identity,
              outcome: :removed,
              violation: false,
              baseline: old,
              current: nil,
              delta_crap: -old.crap,
              delta_complexity: -old.complexity
            }

            {[row | rows], Map.update(summary, :removed, 1, &(&1 + 1))}

          {_baseline_findings, _current_findings} = matched ->
            {row, kind} = apply_row_for_matched(matched, identity, threshold)

            {[row | rows], Map.update(summary, kind, 1, &(&1 + 1))}
        end
      end)

    sorted_rows = rows |> Enum.reverse() |> sort_rows()

    gate_failure_rows =
      Enum.filter(sorted_rows, &(&1.outcome in [:introduced, :regressed] and &1.violation))

    %__MODULE__{
      baseline: baseline,
      current: current,
      threshold: threshold,
      comparable: warnings == [],
      warnings: warnings,
      rows: Enum.take(sorted_rows, limit),
      gate_failure_rows: gate_failure_rows,
      summary: Map.merge(Enum.into(@outcomes, %{}, &{&1, 0}), summary)
    }
  end

  @doc """
  Rows that fail the CI gate: newly introduced violations and regressions
  that end above the threshold. A new-but-clean function or a regression
  that stays under the threshold does not fail the gate — only *new*
  violations do.
  """
  @spec gate_failures(%__MODULE__{}) :: [map()]
  def gate_failures(%__MODULE__{gate_failure_rows: rows}), do: rows

  @doc "CI verdict: fail when there are gate failures."
  @spec gate_passed?(%__MODULE__{}) :: boolean()
  def gate_passed?(%__MODULE__{} = diff), do: diff.comparable and gate_failures(diff) == []

  # ---------------------------------------------------------------- identity

  defp group(findings) do
    Enum.group_by(findings, &identity/1)
  end

  defp identity(%Finding{} = finding) do
    {finding.language, finding.path, finding.module_name, base_name(finding.function_name)}
  end

  # "f/1 (clause 3)" → "f/1": clause suffixes are presentation, not identity.
  defp base_name(name) do
    String.replace(name, ~r/ \(clause \d+\)$/, "")
  end

  # ---------------------------------------------------------------- rows

  defp row_for_new(identity, current_findings, threshold) do
    worst = worst(current_findings)
    violation = worst.crap > threshold

    {
      %{
        identity: identity,
        outcome: :introduced,
        violation: violation,
        baseline: nil,
        current: worst,
        delta_crap: worst.crap,
        delta_complexity: worst.complexity
      },
      :introduced
    }
  end

  defp apply_row_for_matched({baseline_findings, current_findings}, identity, threshold) do
    row_for_matched(identity, baseline_findings, current_findings, threshold)
  end

  defp row_for_matched(identity, baseline_findings, current_findings, threshold) do
    old = worst(baseline_findings)
    new = worst(current_findings)
    delta_crap = round2(new.crap - old.crap)

    kind =
      cond do
        old.crap > threshold and new.crap <= threshold -> :resolved
        delta_crap > 0 -> :regressed
        delta_crap < 0 -> :improved
        true -> :unchanged
      end

    {
      %{
        identity: identity,
        outcome: kind,
        violation: new.crap > threshold,
        baseline: old,
        current: new,
        delta_crap: delta_crap,
        delta_complexity: new.complexity - old.complexity
      },
      kind
    }
  end

  defp worst(findings) do
    Enum.max_by(findings, & &1.crap)
  end

  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row ->
      severity = row_severity(row.outcome)
      {-severity, -abs(row.delta_crap || 0)}
    end)
  end

  defp row_severity(:introduced), do: 4
  defp row_severity(:regressed), do: 3
  defp row_severity(:removed), do: 2
  defp row_severity(:improved), do: 1
  defp row_severity(:resolved), do: 0
  defp row_severity(:unchanged), do: 0

  # ---------------------------------------------------------------- guards

  defp policy_of(%Scan{stats: %{"policy" => p} = stats}) when is_binary(p) and p != "",
    do: {p, Map.get(stats, "parsers", [])}

  defp policy_of(%Scan{stats: _}), do: nil

  defp exclusions_of(%Scan{config: %{"exclude" => e}}), do: e || []
  defp exclusions_of(%Scan{config: _}), do: nil

  defp warn_unless(warnings, condition, message) do
    if condition.(), do: warnings, else: warnings ++ [message]
  end

  defp round2(value), do: Float.round(value * 1.0, 2)
end
