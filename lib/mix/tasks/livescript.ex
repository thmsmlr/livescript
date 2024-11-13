defmodule Mix.Tasks.Livescript do
  use Mix.Task

  def run(["run", exs_path | _]) do
    qualified_exs_path = Path.absname(exs_path) |> Path.expand()
    Logger.put_module_level(Livescript, :info)
    code = File.read!(qualified_exs_path)

    Task.async(fn ->
      preamble_exprs = Livescript.preamble_code(qualified_exs_path)
      Livescript.execute_code(preamble_exprs)
      {:ok, {_, _, exprs}} = Livescript.to_quoted(code)
      executed_exprs = Livescript.execute_code(exprs)

      exit_status = if executed_exprs == exprs, do: 0, else: 1
      hooks = :elixir_config.get_and_put(:at_exit, [])

      for hook <- hooks do
        hook.(exit_status)
      end

      System.halt(exit_status)
    end)
  end

  def run([exs_path | _]) do
    qualified_exs_path = Path.absname(exs_path) |> Path.expand()

    Logger.put_module_level(Livescript, :info)
    Livescript.start_link(qualified_exs_path)
  end
end

defmodule Livescript do
  use GenServer
  require Logger

  @moduledoc """
  This module provides a way to live reload Elixir code in development mode.

  It works by detecting changes in the file and determining which lines of code need
  to be rerun to get to a final consistent state.
  """

  @poll_interval 300

  # Client API

  def start_link(file_path) do
    GenServer.start_link(__MODULE__, %{file_path: file_path})
  end

  # Server callbacks

  @impl true
  def init(%{file_path: file_path} = state) do
    IO.puts(IO.ANSI.yellow() <> "Watching #{file_path} for changes..." <> IO.ANSI.reset())
    schedule_poll()
    state = Map.merge(state, %{executed_exprs: [], last_modified: nil})
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{file_path: file_path, last_modified: nil} = state) do
    # first poll, run the code completely
    with {:ok, %{mtime: mtime}} <- File.stat(file_path),
         {:ok, current_code} <- File.read(file_path),
         {:ok, {_, _, current_exprs}} <- to_quoted(current_code) do
      # Preamble to make argv the same as when the file is run with elixir without livescript
      set_argv_expr = preamble_code(file_path)

      execute_code(set_argv_expr)
      executed_exprs = execute_code(current_exprs)

      {:noreply, %{state | executed_exprs: executed_exprs, last_modified: mtime}}
    else
      {:error, reason} ->
        IO.puts(
          IO.ANSI.red() <>
            "Failed to read & run file #{file_path}: #{inspect(reason)}" <> IO.ANSI.reset()
        )

        {:noreply, %{state | last_modified: File.stat!(file_path).mtime}}
    end
  after
    schedule_poll()
  end

  @impl true
  def handle_info(:poll, %{file_path: file_path} = state) do
    case File.stat(file_path) do
      {:ok, %{mtime: mtime}} ->
        if mtime > state.last_modified do
          [_, current_time] =
            NaiveDateTime.from_erl!(:erlang.localtime())
            |> NaiveDateTime.to_string()
            |> String.split(" ")

          basename = Path.basename(file_path)

          IO.puts(
            IO.ANSI.yellow() <>
              "[#{current_time}] #{basename} has been modified" <> IO.ANSI.reset()
          )

          next_code = File.read!(file_path)

          case to_quoted(next_code) do
            {:ok, {_, _, next_exprs}} ->
              {common_exprs, _rest_exprs, rest_next_exprs} =
                split_at_diff(state.executed_exprs, next_exprs)

              Logger.debug("Common exprs: #{Macro.to_string(common_exprs)}")
              Logger.debug("Next exprs: #{Macro.to_string(rest_next_exprs)}")

              executed_next_exprs = execute_code(rest_next_exprs)

              {:noreply,
               %{
                 state
                 | executed_exprs: common_exprs ++ executed_next_exprs,
                   last_modified: mtime
               }}

            {:error, err} ->
              IO.puts(
                IO.ANSI.red() <>
                  "Syntax error: #{inspect(err)}" <> IO.ANSI.reset()
              )

              {:noreply, %{state | last_modified: mtime}}
          end
        else
          {:noreply, state}
        end

      {:error, _reason} ->
        IO.puts(IO.ANSI.red() <> "Failed to stat file #{file_path}" <> IO.ANSI.reset())
        {:noreply, state}
    end
  catch
    e ->
      IO.puts(IO.ANSI.red() <> "Error: #{inspect(e)}" <> IO.ANSI.reset())
      {:noreply, state}
  after
    schedule_poll()
  end

  # Helper functions

  def preamble_code(file_path) do
    {_, _, preamble_expr} =
      quote do
        System.put_env("__LIVESCRIPT__", "1")
        System.put_env("__LIVESCRIPT_FILE__", unquote(file_path))
        System.argv(unquote(current_argv()))
        IEx.dont_display_result()
      end

    preamble_expr
  end

  defp current_argv() do
    case System.argv() do
      ["livescript", "run", _path | argv] -> argv
      ["livescript", _path | argv] -> argv
      argv -> argv
    end
  end

  def to_quoted(code) do
    Code.string_to_quoted(code)
  end

  def call_home_macro(expr) do
    quote do
      send(
        :erlang.list_to_pid(unquote(:erlang.pid_to_list(self()))),
        unquote(expr)
      )
    end
  end

  def execute_code(code) when is_binary(code) do
    {:ok, {_, _, exprs}} = to_quoted(code)
    execute_code(exprs)
  end

  def execute_code(exprs) when is_list(exprs) do
    num_exprs = length(exprs)

    exprs
    |> Enum.with_index()
    |> Enum.take_while(fn {expr, index} ->
      is_last = index == num_exprs - 1

      code_str = expr |> Macro.to_string()
      {_, opts, _} = expr
      start_line = Keyword.get(opts, :line, 1)

      code =
        case expr do
          {:use, _, _} ->
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
                #{Macro.to_string(call_home_macro(:__livescript_error__))}
                reraise e, __STACKTRACE__
            )
            """
        end

      do_execute_code(code,
        start_line: start_line,
        async: true,
        call_home_with: :__livescript_complete__
      )

      was_successful =
        receive do
          :__livescript_complete__ -> true
          :__livescript_error__ -> false
        end

      if was_successful do
        # Fetch the bindings from the try scope
        do_execute_code(call_home_macro(quote do: Keyword.keys(livescript_binding__)))
        binding_keys = receive do: (x -> x)

        # Set them into the parent scope
        binding_keys
        |> Enum.each(fn k ->
          kvar = Macro.var(k, nil)
          do_execute_code(quote do: unquote(kvar) = livescript_binding__[unquote(k)])
        end)

        if is_last do
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
        ^call_home_with -> true
      end
    end
  end

  defp do_execute_code(exprs, opts) do
    do_execute_code(Macro.to_string(exprs), opts)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  @doc """
  Split two lists at the first difference.
  Returns a tuple with the common prefix, the rest of the first list, and the rest of the second list.
  """
  def split_at_diff(first, second) do
    {prefix, rest1, rest2} = do_split_at_diff(first, second, [])
    {Enum.reverse(prefix), rest1, rest2}
  end

  defp do_split_at_diff([h | t1], [h | t2], acc), do: do_split_at_diff(t1, t2, [h | acc])
  defp do_split_at_diff(rest1, rest2, acc), do: {acc, rest1, rest2}

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
end
