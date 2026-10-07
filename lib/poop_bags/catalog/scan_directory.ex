defmodule PoopBags.Catalog.ScanDirectory do
  @moduledoc """
  One scan's aggregate for one directory group — the durable hotspot record
  that survives retention's expiry of per-function details.

  `depth` is the display level: 1 rows cover a first path segment, 2 rows a
  first-two-segments group. Files directly under a segment that also has
  subdirectories get their own `"<segment>/(direct files)"` row so every
  finding belongs to exactly one group per depth, and root-level files sit in
  `"(root)"`.
  """

  use Ecto.Schema

  schema "scan_directories" do
    field :scan_id, :id
    field :path, :string
    field :depth, :integer, default: 1
    field :files, :integer, default: 0
    field :functions, :integer, default: 0
    field :violations, :integer, default: 0
    field :worst_crap, :float, default: 0.0
    field :crap_excess, :float, default: 0.0
    field :measured_functions, :integer, default: 0
    field :assumed_functions, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
