defmodule Mix.Tasks.Livescript do
  use Mix.Task

  def run([exs_path]) do
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
         {:ok, {_, _, current_exprs}} <- Code.string_to_quoted(current_code) do
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

          case Code.string_to_quoted(next_code) do
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

  defp execute_code(exprs) when is_list(exprs) do
    {iex_evaluator, iex_server} = find_iex()

    num_exprs = length(exprs)

    exprs
    |> Enum.with_index()
    |> Enum.take_while(fn {expr, index} ->
      is_last = index == num_exprs - 1

      callhome_expr =
        quote do
          send(
            :erlang.list_to_pid(unquote(:erlang.pid_to_list(self()))),
            :__livescript_complete__
          )
        end

      code = """
      livescript_result__ = (#{Macro.to_string(expr)})
      #{Macro.to_string(callhome_expr)}
      #{if is_last, do: "livescript_result__", else: "IEx.dont_display_result()"}
      """

      send(iex_evaluator, {:eval, iex_server, code, 1, ""})
      wait_for_iex(iex_evaluator, iex_server, timeout: :infinity)

      receive do
        :__livescript_complete__ -> true
      after
        50 ->
          false
      end
    end)
    |> Enum.map(fn {result, _} -> result end)
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

  defp wait_for_iex(iex_evaluator, iex_server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)

    # Make a request, once we get the response, we know the mailbox is free
    Task.async(fn ->
      send(iex_evaluator, {:fields_from_env, iex_server, nil, self(), []})

      receive do
        x -> x
      end
    end)
    |> Task.await(timeout)
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
end
