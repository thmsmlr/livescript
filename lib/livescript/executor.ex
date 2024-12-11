defmodule Livescript.Executor do
  use GenServer
  require Logger

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def execute(exprs, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, exprs, opts}, :infinity)
  end

  # Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, exprs, opts}, _from, state) do
    result = execute_code(exprs, opts)
    {:reply, result, state}
  end

  # Helper functions moved from Livescript module

  def execute_code(exprs, opts) do
    ignore_last_expression = Keyword.get(opts, :ignore_last_expression, false)
    num_exprs = length(exprs)

    exprs
    |> Enum.with_index()
    |> Enum.take_while(fn {%Livescript.Expression{} = expr, index} ->
      is_last = index == num_exprs - 1
      start_line = expr.line_start

      do_execute_code("livescript_result__ = (#{expr.code})",
        start_line: start_line,
        async: true,
        call_home_with: :success,
        print_result:
          if(is_last and not ignore_last_expression,
            do: "livescript_result__",
            else: "IEx.dont_display_result()"
          )
      )

      do_execute_code("", async: true, call_home_with: :complete)

      # If the status is :success, we need to wait for the :complete message
      # to keep the mailbox clean. Otherwise, there was some kind of error
      was_successful =
        receive do
          {:__livescript__, :success} ->
            receive do: ({:__livescript__, :complete} -> true)

          {:__livescript__, :complete} ->
            false
        end

      was_successful
    end)
    |> Enum.map(fn {expr, _} -> expr end)
  end

  defp do_execute_code(code, opts)

  defp do_execute_code(code, opts) when is_binary(code) do
    {iex_evaluator, iex_server} = find_iex()
    print_result = Keyword.get(opts, :print_result, "IEx.dont_display_result()")
    call_home_with = Keyword.get(opts, :call_home_with, :__livescript_complete__)
    start_line = Keyword.get(opts, :start_line, 1)
    async = Keyword.get(opts, :async, false)

    call_home_expr =
      case call_home_with do
        nil -> nil
        expr -> Macro.to_string(call_home_macro(expr))
      end

    code = """
    #{code}
    #{call_home_expr}
    #{print_result}
    """

    send(iex_evaluator, {:eval, iex_server, code, start_line, ""})

    if not async and is_atom(call_home_with) do
      receive do
        {:__livescript__, ^call_home_with} -> true
      end
    end
  end

  defp do_execute_code(exprs, opts) do
    do_execute_code(Macro.to_string(exprs), opts)
  end

  defp find_iex(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    start_time = System.monotonic_time(:millisecond)
    do_find_iex(timeout, start_time)
  end

  defp do_find_iex(timeout, start_time) do
    :erlang.processes()
    |> Enum.find_value(fn pid ->
      info = Process.info(pid)

      case info[:dictionary][:"$initial_call"] do
        {IEx.Evaluator, _, _} ->
          iex_server = info[:dictionary][:iex_server]
          iex_evaluator = pid
          {iex_evaluator, iex_server}

        _ ->
          nil
      end
    end)
    |> case do
      nil ->
        current_time = System.monotonic_time(:millisecond)

        if current_time - start_time < timeout do
          Process.sleep(10)
          do_find_iex(timeout, start_time)
        else
          raise "Timeout: Could not find IEx process within #{timeout} milliseconds"
        end

      x ->
        x
    end
  end

  def call_home_macro(expr) do
    quote do
      send(
        :erlang.list_to_pid(unquote(:erlang.pid_to_list(self()))),
        {:__livescript__, unquote(expr)}
      )
    end
  end
end
