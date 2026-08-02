defmodule TimelessUI.TelemetryDataPlaneStartupFixture do
  @moduledoc false

  def prepare(data_dir, opts) do
    case Keyword.get(opts, :fixture_result, :ready) do
      :ready ->
        File.mkdir_p!(data_dir)
        target = Path.join(data_dir, "fixture.db")
        File.write!(target, "fixture")
        {:ok, %{ready: true, state: :valid_libsql, target_path: target}}

      {:error, reason} ->
        {:error, %{ready: false, state: :corruption, error: reason}}
    end
  end

  def stats(data_dir, opts) do
    case Keyword.get(opts, :fixture_result, :ready) do
      :ready ->
        %{
          ready: File.regular?(Path.join(data_dir, "fixture.db")),
          state: :valid_libsql,
          migration_phase: "complete",
          completed_records: 1,
          records_total: 1
        }

      {:error, reason} ->
        %{ready: false, state: :corruption, error: reason}
    end
  end
end
