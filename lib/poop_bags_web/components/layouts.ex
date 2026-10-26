defmodule PoopBagsWeb.Layouts do
  @moduledoc """
  The layouts: `root` is the html skeleton (router-level), `app` wraps page
  content with the site chrome. Flash lives here — no client JS, rendered
  server-side on the next request.
  """

  use PoopBagsWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, default: %{}, doc: "the map of flash messages"

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group">
      <%= if message = Phoenix.Flash.get(@flash, :info) do %>
        <div class="flash flash-info">{message}</div>
      <% end %>
      <%= if message = Phoenix.Flash.get(@flash, :error) do %>
        <div class="flash flash-error">{message}</div>
      <% end %>
    </div>
    """
  end
end
