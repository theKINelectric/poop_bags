defmodule PoopBags.Walker do
  @moduledoc """
  Walks a project directory and returns every source file worth bagging —
  known languages only, junk directories and oversized files excluded. A
  `PoopBags.ProjectConfig` adds its exclusion globs and language filter;
  excluded files count as skipped.
  """

  alias PoopBags.Languages
  alias PoopBags.ProjectConfig

  @type file_entry :: %{path: String.t(), rel_path: String.t(), language: atom()}

  @doc """
  Collects `%{path, rel_path, language}` entries under `root`, capped at
  `Languages.max_files/0` (deterministic: sorted traversal, then truncation)
  — files past the cap are reported as skipped.
  """
  @spec collect(Path.t(), ProjectConfig.t() | nil) :: {[file_entry()], non_neg_integer()}
  def collect(root, config \\ nil) do
    root = Path.expand(root)

    {files, skipped} =
      do_walk([root], root, config, _acc = [], _skipped = 0, _budget = Languages.max_files())

    cap = Languages.max_files()

    if length(files) <= cap do
      {files, skipped}
    else
      {Enum.take(files, cap), skipped + length(files) - cap}
    end
  end

  defp do_walk([], _root, _config, acc, skipped, _budget), do: {Enum.reverse(acc), skipped}

  defp do_walk(_dirs, _root, _config, acc, skipped, budget) when budget <= 0,
    do: {Enum.reverse(acc), skipped}

  defp do_walk([dir | rest], root, config, acc, skipped, budget) do
    case File.ls(dir) do
      {:ok, names} ->
        # Sorted names: same directory, same harvest, every time.
        {subdirs, files, dir_skipped} = split_entries(dir, root, config, Enum.sort(names))

        do_walk(
          Enum.reverse(subdirs) ++ rest,
          root,
          config,
          files ++ acc,
          skipped + dir_skipped,
          budget - length(files)
        )

      {:error, _} ->
        do_walk(rest, root, config, acc, skipped + 1, budget)
    end
  end

  defp split_entries(dir, root, config, names) do
    Enum.reduce(names, {[], [], 0}, fn name, {dirs, files, skipped} ->
      path = Path.join(dir, name)

      cond do
        Languages.junk_dir?(name) ->
          {dirs, files, skipped}

        # Symlinks are not followed: a cycle would loop the walk forever.
        match?({:ok, %{type: :symlink}}, File.lstat(path)) ->
          {dirs, files, skipped}

        File.dir?(path) ->
          {[path | dirs], files, skipped}

        true ->
          case entry_for(path, root, config) do
            {:ok, entry} -> {dirs, [entry | files], skipped}
            :oversize -> {dirs, files, skipped + 1}
            :excluded -> {dirs, files, skipped + 1}
            :ignore -> {dirs, files, skipped}
          end
      end
    end)
  end

  # Oversize files are counted as skipped rather than silently vanishing —
  # `files_skipped` on the scan row must not lie. Config-excluded files too.
  defp entry_for(path, root, nil), do: entry_for(path, root, %ProjectConfig{})

  defp entry_for(path, root, %ProjectConfig{} = config) do
    rel = path |> Path.relative_to(root) |> Path.split() |> Enum.join("/")

    cond do
      ProjectConfig.excluded?(config, rel) ->
        :excluded

      true ->
        max_bytes = Languages.max_file_bytes()

        case Languages.language_for(path) do
          nil ->
            :ignore

          language ->
            if ProjectConfig.language_allowed?(config, language) do
              case File.stat(path) do
                {:ok, %{size: size}} when size > max_bytes -> :oversize
                {:ok, _} -> {:ok, entry(path, rel, language)}
                _ -> :ignore
              end
            else
              :ignore
            end
        end
    end
  end

  defp entry(path, rel, language) do
    %{path: path, rel_path: rel, language: language}
  end
end
