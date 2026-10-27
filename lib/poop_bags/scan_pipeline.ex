defmodule PoopBags.ScanPipeline do
  @moduledoc """
  The conveyor belt, built on `FlowExtra.Pipeline` (the Flowex fork riding
  GenStage under the hood).

  Each Information Packet is one source file:

      load_file → analyze_file → attach_coverage → score_findings

  * `load_file`       — reads the file off disk (replicated ×6)
  * `analyze_file`    — runs the language analyzer, producing per-function
                        findings with line spans (replicated ×6)
  * `attach_coverage` — maps ingested report lines onto the innermost
                        function spans; unmeasured functions keep provenance
                        `\"unknown\"` (replicated ×3)
  * `score_findings`  — applies the CRAP formula with each function's own
                        coverage — measured if the report spoke, the scan's
                        assumed value otherwise (replicated ×3)

  Pipeline options: `coverage` (assumed fallback ratio) and `line_coverage`
  (`%{rel_path => %{line => hits}}` from an ingested report, or nil).

  Any raise along the belt is routed to `bag_the_mess`, which bags the file
  as failed (with the reason) instead of taking the pipeline down — one
  unreadable file never ends the scan.
  """

  use FlowExtra.Pipeline

  alias PoopBags.Analysis
  alias PoopBags.Coverage
  alias PoopBags.Crap
  alias PoopBags.Languages

  defstruct [
    :path,
    :rel_path,
    :language,
    :source,
    :findings,
    :parser_meta,
    :failed_reason,
    :hash,
    :size,
    analyzer_skips: [],
    skipped: false
  ]

  pipe(:load_file, count: 6)
  pipe(:analyze_file, count: 6)
  pipe(:attach_coverage, count: 3)
  pipe(:score_findings, count: 3)
  error_pipe(:bag_the_mess)

  @doc "Builds the IP for one file entry from the walker."
  def ip_for(%{path: path, rel_path: rel_path, language: language}) do
    %__MODULE__{path: path, rel_path: rel_path, language: language}
  end

  def load_file(ip, _opts) do
    max_bytes = Languages.max_file_bytes()

    case File.stat(ip.path) do
      {:ok, %{size: size}} when size > max_bytes ->
        %{ip | skipped: true, size: size}

      {:ok, %{size: size}} ->
        case File.read(ip.path) do
          {:ok, source} ->
            hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

            %{ip | source: source, size: size, hash: hash}

          {:error, reason} ->
            raise File.Error, reason: reason, action: "read", path: ip.path
        end

      other ->
        raise File.Error, reason: elem(other, 1), action: "stat", path: ip.path
    end
  end

  def analyze_file(%{skipped: true} = ip, _opts), do: ip

  def analyze_file(ip, _opts) do
    case Analysis.analyze_with_meta(ip.source, ip.language, path: ip.rel_path) do
      {:ok, findings, metadata} ->
        # The source text is dead weight past this point; drop it so the
        # belt doesn't carry every file's bytes to the end of the line.
        %{
          ip
          | source: nil,
            findings: findings,
            parser_meta: metadata && Map.delete(metadata, "skipped"),
            analyzer_skips: if(metadata, do: Map.get(metadata, "skipped", []), else: [])
        }

      {:error, reason} ->
        raise ArgumentError,
          message: "could not parse #{ip.rel_path} as #{ip.language}: #{inspect(reason)}"
    end
  end

  def attach_coverage(%{skipped: true} = ip, _opts), do: ip

  def attach_coverage(ip, opts) do
    lines =
      opts
      |> Map.get(:line_coverage)
      |> case do
        nil -> %{}
        report -> Map.get(report, ip.rel_path, %{})
      end

    %{ip | findings: Coverage.attach(ip.findings, lines)}
  end

  def score_findings(%{skipped: true} = ip, _opts), do: ip

  def score_findings(ip, opts) do
    assumed = Map.get(opts, :coverage, 0.0)

    findings =
      Enum.map(ip.findings, fn finding ->
        {ratio, source} =
          case finding do
            %{coverage: nil, coverage_source: "unknown"} -> {assumed, "assumed"}
            %{coverage: nil} -> {assumed, "assumed"}
            %{coverage: ratio, coverage_source: source} -> {ratio, source}
          end

        finding
        |> Map.from_struct()
        |> Map.put(:crap, Crap.score(finding.complexity, ratio))
        |> Map.put(:coverage, ratio)
        |> Map.put(:coverage_source, source)
      end)

    %{ip | findings: findings}
  end

  def bag_the_mess(error, ip, _opts) do
    reason =
      case error do
        %{message: message} when is_binary(message) -> message
        other -> inspect(other)
      end

    %{ip | failed_reason: reason, findings: []}
  end
end
