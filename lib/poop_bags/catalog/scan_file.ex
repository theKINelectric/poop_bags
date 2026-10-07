defmodule PoopBags.Catalog.ScanFile do
  @moduledoc """
  One file of a scan's manifest: path, size, and content hash — the
  snapshot identity that coverage attribution and future caching lean on.
  """

  use Ecto.Schema

  schema "scan_files" do
    field :scan_id, :id
    field :path, :string
    field :size, :integer, default: 0
    field :hash, :string

    timestamps(type: :utc_datetime_usec)
  end
end
