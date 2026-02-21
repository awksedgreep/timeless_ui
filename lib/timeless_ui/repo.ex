defmodule TimelessUI.Repo do
  use Ecto.Repo,
    otp_app: :timeless_ui,
    adapter: Ecto.Adapters.SQLite3
end
