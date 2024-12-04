defmodule Livescript.Expression do
  defstruct [:quoted, :code, :line_start, :line_end]
end

defmodule Livescript do
  use GenServer
  require Logger

  alias Livescript.Expression

  @moduledoc """
  This module provides a way to live reload Elixir code in development mode.

  It works by detecting changes in the file and determining which lines of code need
  to be rerun to get to a final consistent state.
  """

  @poll_interval 300

  # Client API

  def start_link(file_path) do
    GenServer.start_link(__MODULE__, %{file_path: file_path}, name: __MODULE__)
  end

  @doc """
  Run the expressions after the given line number.

  Note: if you are running this from the IEx shell in a livescript session
  there will be a deadlock. Instead, execute it from a Task as shown,

      Task.async(fn -> Livescript.run_after_cursor(27) end)
  """
  def run_after_cursor(code, line_number) when is_integer(line_number) and is_binary(code) do
    GenServer.call(__MODULE__, {:run_after_cursor, code, line_number})
  end

  def run_at_cursor(code, line_number, line_end, mode \\ :expression)
      when is_integer(line_number) and is_integer(line_end) and is_binary(code) do
    GenServer.call(__MODULE__, {:run_at_cursor, code, line_number, line_end, mode})
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
  def handle_call({:run_after_cursor, code, line_number}, from, %{file_path: _file_path} = state) do
    with {:ok, exprs} <- parse_code(code) do
      exprs_after =
        exprs
        |> Enum.filter(fn %Expression{line_start: min_line} ->
          min_line >= line_number
        end)

      IO.puts(IO.ANSI.yellow() <> "Running code after line #{line_number}:" <> IO.ANSI.reset())

      Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
        executed_exprs = Livescript.Executor.execute(exprs_after)
        GenServer.reply(from, :ok)
        {:done_executing, executed_exprs}
      end)

      {:noreply, state}
    else
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(
        {:run_at_cursor, code, line_start, line_end, mode},
        from,
        %{file_path: _file_path} = state
      ) do
    opts = if mode == :block, do: [block_mode: true], else: []

    with {:ok, exprs} <- parse_code(code, opts) do
      exprs_at =
        exprs
        |> Enum.filter(fn %Expression{line_start: expr_start, line_end: expr_end} ->
          # Expression overlaps with selection if:
          # - Expression starts within selection, OR
          # - Expression ends within selection, OR
          # - Expression completely contains selection
          (expr_start >= line_start && expr_start <= line_end) ||
            (expr_end >= line_start && expr_end <= line_end) ||
            (expr_start <= line_start && expr_end >= line_end)
        end)

      mode_str = if mode == :block, do: "block", else: "expression"

      range_str =
        if line_start == line_end,
          do: "line #{line_start}",
          else: "lines #{line_start}-#{line_end}"

      IO.puts(IO.ANSI.yellow() <> "Running #{mode_str} at #{range_str}:" <> IO.ANSI.reset())

      Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
        executed_exprs = Livescript.Executor.execute(exprs_at)
        GenServer.reply(from, :ok)
        {:done_executing, executed_exprs}
      end)

      {:noreply, state}
    else
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:poll, %{file_path: file_path} = state) do
    mtime = File.stat!(file_path).mtime

    with {:modified, true} <-
           {:modified, state.last_modified == nil || mtime > state.last_modified},
         {:read_file, {:ok, next_code}} <- {:read_file, File.read(file_path)},
         {:parse_code, {:ok, next_exprs}} <- {:parse_code, parse_code(next_code)} do
      # Print modification message (except for first run)
      if state.last_modified != nil do
        [_, current_time] =
          NaiveDateTime.from_erl!(:erlang.localtime())
          |> NaiveDateTime.to_string()
          |> String.split(" ")

        basename = Path.basename(file_path)

        IO.puts(
          IO.ANSI.yellow() <>
            "[#{current_time}] #{basename} has been modified" <> IO.ANSI.reset()
        )
      end

      # For first run, execute preamble
      if state.last_modified == nil do
        preamble_code(file_path)
        |> Livescript.Executor.execute()
      end

      # Calculate which expressions to run
      {common_exprs, rest_next_exprs} =
        if state.last_modified == nil do
          {[], next_exprs}
        else
          {common, _rest_exprs, _rest_next} =
            split_at_diff(
              Enum.map(state.executed_exprs, & &1.quoted),
              Enum.map(next_exprs, & &1.quoted)
            )

          {Enum.take(next_exprs, length(common)), Enum.drop(next_exprs, length(common))}
        end

      Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
        executed_exprs = Livescript.Executor.execute(rest_next_exprs)
        {:done_executing, common_exprs ++ executed_exprs, mtime}
      end)

      {:noreply, %{state | last_modified: mtime}}
    else
      {:modified, false} ->
        {:noreply, state}

      {:read_file, {:error, err}} ->
        IO.puts(
          IO.ANSI.red() <>
            "Failed to process file: #{inspect(err)}" <> IO.ANSI.reset()
        )

        {:noreply, %{state | last_modified: mtime}}

      {:parse_code, {:error, reason}} ->
        IO.puts(
          IO.ANSI.red() <>
            "Failed to parse file: #{inspect(reason)}" <> IO.ANSI.reset()
        )

        {:noreply, %{state | last_modified: mtime}}
    end
  catch
    e ->
      IO.puts(IO.ANSI.red() <> "Error: #{inspect(e)}" <> IO.ANSI.reset())
      {:noreply, state}
  after
    schedule_poll()
  end

  @impl true
  def handle_info({_ref, {:done_executing, exprs}}, state) do
    {:noreply, %{state | executed_exprs: exprs}}
  end

  @impl true
  def handle_info({_ref, {:done_executing, exprs, last_modified}}, state) do
    {:noreply, %{state | executed_exprs: exprs, last_modified: last_modified}}
  end

  def handle_info({:DOWN, _ref, _, _, :normal}, state) do
    {:noreply, state}
  end

  # Helper functions

  def preamble_code(file_path) do
    code =
      quote do
        System.put_env("__LIVESCRIPT__", "1")
        System.put_env("__LIVESCRIPT_FILE__", unquote(file_path))
        System.argv(unquote(current_argv()))
        IEx.dont_display_result()
      end
      |> Macro.to_string()

    {:ok, exprs} = parse_code(code)
    exprs
  end

  defp current_argv() do
    case System.argv() do
      ["livescript", "run", _path | argv] -> argv
      ["livescript", _path | argv] -> argv
      argv -> argv
    end
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

  @doc """
  Parse the code and return a list of expressions with the line range.

  It parses the code twice to get the precise line range (see [string_to_quoted/2](https://hexdocs.pm/elixir/1.17.2/Code.html#quoted_to_algebra/2-formatting-considerations)).
  """
  def parse_code(code, opts \\ []) do
    parse_opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      unescape: false
    ]

    with {:ok, quoted} <- string_to_quoted_expressions(code),
         {:ok, precise_quoted} <- string_to_quoted_expressions(code, parse_opts) do
      exprs =
        Enum.zip(quoted, precise_quoted)
        |> Enum.map(fn {quoted, precise_quoted} ->
          {line_start, line_end} = line_range(precise_quoted)
          amount_of_lines = max(line_end - line_start + 1, 0)

          code =
            code
            |> String.split("\n")
            |> Enum.slice(line_start - 1, amount_of_lines)
            |> Enum.join("\n")

          %Livescript.Expression{
            quoted: quoted,
            code: code,
            line_start: line_start,
            line_end: line_end
          }
        end)

      exprs =
        if Keyword.get(opts, :block_mode, false) do
          merge_adjacent_expressions(exprs)
        else
          exprs
        end

      {:ok, exprs}
    end
  end

  defp string_to_quoted_expressions(code, opts \\ []) do
    case Code.string_to_quoted(code, opts) do
      {:ok, {:__block__, _, quoted}} -> {:ok, quoted}
      {:ok, quoted} -> {:ok, [quoted]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Merges adjacent expressions into blocks. Two expressions are considered adjacent
  if the end line of one expression is immediately followed by the start line of another.
  """
  def merge_adjacent_expressions(exprs) do
    exprs
    |> Enum.sort_by(& &1.line_start)
    |> Enum.reduce([], fn expr, acc ->
      case acc do
        [prev | rest] when prev.line_end + 1 == expr.line_start ->
          # Merge the expressions into a block
          merged = %Livescript.Expression{
            quoted: {:__block__, [], [prev.quoted, expr.quoted]},
            code: prev.code <> "\n" <> expr.code,
            line_start: prev.line_start,
            line_end: expr.line_end
          }

          [merged | rest]

        _ ->
          [expr | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp line_range({_, opts, nil}) do
    line_start = opts[:line] || :infinity
    line_end = opts[:end_of_expression][:line] || opts[:last][:line] || opts[:closing][:line] || 0
    {line_start, line_end}
  end

  defp line_range({_, opts, children}) do
    line_start = opts[:line] || :infinity
    line_end = opts[:end_of_expression][:line] || opts[:last][:line] || opts[:closing][:line] || 0

    {child_min, child_max} =
      children
      |> Enum.map(&line_range/1)
      |> Enum.unzip()

    {
      Enum.min([line_start | child_min]),
      Enum.max([line_end | child_max])
    }
  end

  defp line_range(_), do: {:infinity, 0}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
