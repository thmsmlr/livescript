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

  def execute_code(exprs, opts \\ []) do
    num_exprs = length(exprs)

    exprs
    |> Enum.with_index()
    |> Enum.take_while(fn {%Livescript.Expression{} = expr, index} ->
      is_last = index == num_exprs - 1

      code_str = expr.code
      start_line = expr.line_start

      code =
        case expr.quoted do
          {:use, _, _} ->
            code_str

          {:require, _, _} ->
            code_str

          {:import, _, _} ->
            code_str

          {:alias, _, _} ->
            code_str

          {_, _, _} ->
            """
            {livescript_result__, livescript_binding__} = try do: (livescript_result__ = (#{code_str})
              livescript_binding__ = binding() |> Keyword.filter(fn {k, _} -> k not in [:livescript_binding__, :livescript_result__] end)
              {livescript_result__, livescript_binding__}
            ), rescue: (
              e ->
                #{Macro.to_string(call_home_macro(:error))}
                reraise e, __STACKTRACE__
            )
            """
        end

      do_execute_code(code,
        start_line: start_line,
        async: true,
        call_home_with: :complete
      )

      was_successful =
        receive do
          {:__livescript__, :complete} -> true
          {:__livescript__, :error} -> false
        end

      if was_successful do
        # Fetch the bindings from the try scope
        do_execute_code(call_home_macro(quote do: Keyword.keys(livescript_binding__)))
        binding_keys = receive do: ({:__livescript__, x} -> x)

        # Set them into the parent scope
        binding_keys
        |> Enum.each(fn k ->
          kvar = Macro.var(k, nil)
          do_execute_code(quote do: unquote(kvar) = livescript_binding__[unquote(k)])
        end)

        ignore_last_expression = Keyword.get(opts, :ignore_last_expression, false)

        if is_last and not ignore_last_expression do
          do_execute_code("", print_result: "livescript_result__")
        end

        true
      else
        false
      end
    end)
    |> Enum.map(fn {expr, _} -> expr end)
  end

  defp do_execute_code(code, opts \\ [])

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
