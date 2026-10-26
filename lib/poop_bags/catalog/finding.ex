defmodule PoopBags.Catalog.Finding do
  @moduledoc """
  One bagged specimen: a single function's complexity and CRAP score.
  """

  use Ecto.Schema

  schema "findings" do
    field :scan_id, :id
    field :language, :string
    field :path, :string
    field :module_name, :string, default: ""
    field :function_name, :string
    field :line, :integer, default: 1
    field :end_line, :integer, default: 1
    field :complexity, :integer, default: 1
    field :crap, :float, default: 0.0
    # The coverage ratio used when scoring, and its provenance:
    # "measured" (from an ingested report), "assumed" (the scan's fallback).
    field :coverage, :float
    field :coverage_source, :string, default: "assumed"

    timestamps(type: :utc_datetime_usec)
  end
end
