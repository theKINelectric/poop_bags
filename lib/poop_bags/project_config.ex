defmodule PoopBags.ProjectConfig do
  @moduledoc """
  Per-project configuration from `<project>/.poopbags.json`, merged with the
  caller's overrides (web form / CLI flags / API).

  Parsed as strict JSON — a scanned project is untrusted input; no `.exs`
  evaluation. Precedence: built-in defaults < project file < overrides.

      {
        "exclude": ["experiments/**", "**/*.gen.zig"],
        "coverage_report": "cover/lcov.info",
        "threshold": 30,
        "languages": ["zig", "elixir"],
        "hotspot_depth": 2
      }

  `coverage_report` is resolved relative to the project root. The effective
  configuration and a digest of the source file are persisted with each scan.
  """

  alias PoopBags.Languages

  @config_filename ".poopbags.json"

  @defaults %{
    "exclude" => [],
    "coverage_report" => nil,
    "threshold" => 20.0,
    "languages" => nil,
    "hotspot_depth" => 2
  }

  defstruct exclude: [],
            coverage_report: nil,
            threshold: 20.0,
            languages: nil,
            hotspot_depth: 2,
            digest: "none",
            source: "defaults",
            compiled: []

  @type t :: %__MODULE__{
          exclude: [String.t()],
          coverage_report: String.t() | nil,
          threshold: float(),
          languages: [atom()] | nil,
          hotspot_depth: pos_integer(),
          digest: String.t(),
          source: String.t(),
          compiled: [Regex.t()]
        }

  @doc "Loads `<root>/.poopbags.json` and merges `overrides` (string keys)."
  @spec load(Path.t(), map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(root, overrides \\ %{}) do
    root = Path.expand(root)
    path = Path.join(root, @config_filename)

    with {:ok, raw, digest} <- read_config(path),
         {:ok, parsed} <- parse_config(raw, path) do
      merged =
        @defaults
        |> Map.merge(normalize(parsed))
        |> Map.merge(normalize(Map.new(overrides)))

      config = %__MODULE__{
        exclude: merged["exclude"] || [],
        coverage_report: resolve_report(root, merged["coverage_report"]),
        threshold: to_float(merged["threshold"], 20.0),
        languages: parse_languages(merged["languages"]),
        hotspot_depth: to_depth(merged["hotspot_depth"]),
        digest: digest,
        source: if(File.exists?(path), do: @config_filename, else: "defaults"),
        compiled: Enum.map(merged["exclude"] || [], &PoopBags.Glob.compile/1)
      }

      {:ok, config}
    end
  end

  @doc "The effective config as a JSON-ready map, persisted with the scan."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = config) do
    %{
      "exclude" => config.exclude,
      "coverage_report" => config.coverage_report,
      "threshold" => config.threshold,
      "languages" => config.languages && Enum.map(config.languages, &to_string/1),
      "hotspot_depth" => config.hotspot_depth,
      "source" => config.source,
      "digest" => config.digest
    }
  end

  @doc "Is this project-relative path excluded by the config's globs?"
  @spec excluded?(t(), String.t()) :: boolean()
  def excluded?(%__MODULE__{compiled: compiled}, rel_path) do
    compiled != [] and Enum.any?(compiled, &Regex.match?(&1, rel_path))
  end

  @doc "Restrict to configured languages, if any."
  @spec language_allowed?(t(), atom()) :: boolean()
  def language_allowed?(%__MODULE__{languages: nil}, _language), do: true
  def language_allowed?(%__MODULE__{languages: langs}, language), do: language in langs

  defp read_config(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, raw, :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)}

      {:error, :enoent} ->
        {:ok, "{}", "none"}

      {:error, reason} ->
        {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_config(raw, path) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, "#{path} must contain a JSON object"}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "#{path} is not valid JSON: #{Exception.message(e)}"}
    end
  end

  defp normalize(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp resolve_report(_root, nil), do: nil
  defp resolve_report(_root, ""), do: nil

  # A configured-but-missing report stays configured: the engine's ingest
  # then treats it as a broken report (CI fails, web warns) instead of
  # silently degrading to assumed-only coverage.
  defp resolve_report(root, rel) when is_binary(rel),
    do: Path.expand(rel, root)

  defp to_float(nil, default), do: default

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value * 1.0
  defp to_float(_value, default), do: default

  # Hotspot grouping depth: 1–4 path segments, default 2. JSON floats
  # (3.0) count as their integer.
  defp to_depth(nil), do: 2

  defp to_depth(value) when is_integer(value), do: value |> max(1) |> min(4)

  defp to_depth(value) when is_float(value), do: to_depth(round(value))

  defp to_depth(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> to_depth(n)
      _ -> 2
    end
  end

  defp to_depth(_), do: 2

  defp parse_languages(nil), do: nil

  defp parse_languages(list) when is_list(list) do
    list
    |> Enum.map(fn
      lang when is_binary(lang) ->
        Enum.find(Languages.known_languages(), &(Atom.to_string(&1) == lang))

      lang when is_atom(lang) ->
        lang

      _ ->
        nil
    end)
    |> Enum.filter(&(&1 in Languages.known_languages()))
    |> case do
      [] -> nil
      langs -> langs
    end
  end

  defp parse_languages(_), do: nil
end
