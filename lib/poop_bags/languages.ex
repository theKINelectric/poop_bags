defmodule PoopBags.Languages do
  @moduledoc """
  The languages poop_bags knows how to bag: extension mapping and the
  directories it refuses to sniff (caches, build output, vendored copies).
  """

  @extensions %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".zig" => :zig,
    ".kt" => :kotlin,
    ".kts" => :kotlin,
    ".swift" => :swift,
    ".rs" => :rust,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".mjs" => :javascript,
    ".cjs" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :typescript,
    ".mts" => :typescript,
    ".cts" => :typescript
  }

  # Build output, dependency caches, and vendored third-party trees are not
  # *your* crap. Named case-sensitively; the common ones are lowercase.
  @junk_dirs MapSet.new([
               ".git",
               ".hg",
               ".svn",
               ".zig-cache",
               "zig-cache",
               "zig-cache-global",
               "cache",
               ".cache",
               ".parcel-cache",
               ".next",
               ".nuxt",
               ".turbo",
               ".svelte-kit",
               ".gradle",
               ".swiftpm",
               ".venv",
               "venv",
               "__pycache__",
               ".dart_tool",
               ".expo",
               ".terraform",
               ".DS_Store",
               "_build",
               "deps",
               "node_modules",
               "zig-out",
               "build",
               "Build",
               "DerivedData",
               "coverage",
               "dist",
               "out",
               "Pods",
               "vendor",
               "target"
             ])

  @max_files 30_000
  @max_file_bytes 1_500_000

  def extension_map, do: @extensions

  def language_for(path) do
    if Regex.match?(~r/\.d\.(?:ts|mts|cts)$/, path),
      do: nil,
      else: Map.get(@extensions, Path.extname(path))
  end

  def junk_dir?(name), do: MapSet.member?(@junk_dirs, name)

  def max_files, do: @max_files
  def max_file_bytes, do: @max_file_bytes

  def known_languages, do: ~w(elixir zig kotlin swift rust javascript typescript)a
end
