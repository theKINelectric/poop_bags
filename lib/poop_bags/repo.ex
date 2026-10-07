defmodule PoopBags.Repo do
  use Ecto.Repo,
    otp_app: :poop_bags,
    adapter: Ecto.Adapters.SQLite3
end
