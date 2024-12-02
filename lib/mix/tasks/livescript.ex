defmodule Mix.Tasks.Livescript do
  use Mix.Task

  def run(["run", exs_path | _]) do
    qualified_exs_path = Path.absname(exs_path) |> Path.expand()
    Logger.put_module_level(Livescript, :info)
    code = File.read!(qualified_exs_path)

    Task.async(fn ->
      children = [
        {Livescript.Executor, []}
      ]

      opts = [strategy: :one_for_one, name: Livescript.Supervisor]
      {:ok, _} = Supervisor.start_link(children, opts)

      preamble_exprs = Livescript.preamble_code(qualified_exs_path)
      Livescript.Executor.execute(preamble_exprs)
      {:ok, exprs} = Livescript.parse_code(code)
      executed_exprs = Livescript.Executor.execute(exprs)

      exit_status = if executed_exprs == exprs, do: 0, else: 1
      hooks = :elixir_config.get_and_put(:at_exit, [])

      for hook <- hooks do
        hook.(exit_status)
      end

      System.halt(exit_status)
    end)
  end

  def run([exs_path | _]) do
    # This has to be async because otherwise Mix doesn't start the iex shell
    # until this function returns
    Task.async(fn ->
      qualified_exs_path = Path.absname(exs_path) |> Path.expand()
      Logger.put_module_level(Livescript, :info)
      {:ok, _} = Livescript.App.start(:normal, [qualified_exs_path])
      Process.sleep(:infinity)
    end)
  end
end
