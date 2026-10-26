defmodule PoopBags.Analysis.Finding do
  @moduledoc """
  One function-sized specimen, before scoring: where it lives and how
  branching its body is.
  """

  defstruct module_name: "",
            function_name: "",
            line: 1,
            end_line: 1,
            complexity: 1,
            coverage: nil,
            coverage_source: "unknown"

  @type t :: %__MODULE__{
          module_name: String.t(),
          function_name: String.t(),
          line: pos_integer(),
          end_line: pos_integer(),
          complexity: pos_integer(),
          coverage: float() | nil,
          coverage_source: String.t()
        }
end
