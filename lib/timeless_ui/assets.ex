defmodule TimelessUI.Assets do
  @moduledoc """
  Plug that serves pre-compiled TimelessUI assets from `priv/static/assets/`.

  Used when TimelessUI is embedded in a host application that doesn't serve
  TimelessUI's assets through its own static pipeline.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
    # path_info will be ["timeless_ui", "assets", ...rest]
    # We want to serve from priv/static/assets/...rest
    asset_path = path_info |> List.last() |> sanitize_path()

    case asset_path do
      nil ->
        Plug.Conn.send_resp(conn, 404, "Not found")

      path ->
        priv_dir = :code.priv_dir(:timeless_ui)
        full_path = Path.join([priv_dir, "static", "assets", path])

        if File.exists?(full_path) do
          conn
          |> Plug.Conn.put_resp_content_type(MIME.from_path(path))
          |> Plug.Conn.send_resp(200, File.read!(full_path))
        else
          Plug.Conn.send_resp(conn, 404, "Not found")
        end
    end
  end

  defp sanitize_path(nil), do: nil

  defp sanitize_path(path) do
    if String.contains?(path, "..") do
      nil
    else
      path
    end
  end
end
