defmodule TimelessUI.TelemetryDataPlaneStartupFixture do
  @moduledoc false

  def prepare(data_dir, opts) do
    case Keyword.get(opts, :fixture_result, :ready) do
      :ready ->
        File.mkdir_p!(data_dir)
        target = target(data_dir, opts)

        case Keyword.get(opts, :create_file, true) do
          :sqlite ->
            {:ok, connection} = Exqlite.Sqlite3.open(target)
            :ok = Exqlite.Sqlite3.close(connection)

          true ->
            File.write!(target, "fixture")

          false ->
            :ok
        end

        {:ok, %{ready: true, state: :valid_libsql, target_path: target}}

      {:error, reason} ->
        {:error, %{ready: false, state: :corruption, error: reason}}
    end
  end

  def stats(data_dir, opts) do
    case Keyword.get(opts, :fixture_result, :ready) do
      :ready ->
        %{
          ready: File.regular?(target(data_dir, opts)),
          state: :valid_libsql,
          migration_phase: "complete",
          completed_records: 1,
          records_total: 1
        }

      {:error, reason} ->
        %{ready: false, state: :corruption, error: reason}
    end
  end

  defp target(data_dir, opts),
    do: Path.join(data_dir, Keyword.get(opts, :target_name, "fixture.db"))
end
