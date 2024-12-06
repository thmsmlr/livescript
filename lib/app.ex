defmodule Livescript.App do
  use Application

  def start(_type, [script_path]) do
    qualified_script_path = Path.absname(script_path) |> Path.expand()

    children = [
      {Task.Supervisor, name: Livescript.TaskSupervisor},
      {Livescript.Broadcast, []},
      {Livescript.Executor, []},
      {Livescript, qualified_script_path},
      {Task, fn -> Livescript.TCP.server() end}
    ]

    opts = [strategy: :one_for_one, name: Livescript.Supervisor]
    {:ok, _} = Supervisor.start_link(children, opts)
  end
end
