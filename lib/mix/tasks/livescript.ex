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

      children = [
        {Task.Supervisor, name: Livescript.TaskSupervisor},
        {Livescript.Executor, []},
        {Livescript, qualified_exs_path},
        {Task, fn -> Livescript.TCP.server() end}
      ]

      opts = [strategy: :one_for_one, name: Livescript.Supervisor]
      {:ok, _} = Supervisor.start_link(children, opts)
      Process.sleep(:infinity)
    end)
  end
end

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
  def run_after_cursor(line_number) when is_integer(line_number) do
    GenServer.call(__MODULE__, {:run_after_cursor, line_number})
  end

  def run_after_cursor(code, line_number) when is_integer(line_number) and is_binary(code) do
    GenServer.call(__MODULE__, {:run_after_cursor, code, line_number})
  end

  def run_at_cursor(line_number) when is_integer(line_number) do
    run_at_cursor(line_number, :expression)
  end

  def run_at_cursor(line_number, mode) when is_integer(line_number) do
    GenServer.call(__MODULE__, {:run_at_cursor, line_number, mode})
  end

  def run_at_cursor(code, line_number) when is_integer(line_number) and is_binary(code) do
    run_at_cursor(code, line_number, :expression)
  end

  def run_at_cursor(code, line_number, mode) when is_integer(line_number) and is_binary(code) do
    GenServer.call(__MODULE__, {:run_at_cursor, code, line_number, mode})
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
  def handle_call({:run_after_cursor, line_number}, from, %{file_path: file_path} = state) do
    code = File.read!(file_path)
    handle_call({:run_after_cursor, code, line_number}, from, state)
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
  def handle_call({:run_at_cursor, line_number, mode}, from, %{file_path: file_path} = state) do
    code = File.read!(file_path)
    handle_call({:run_at_cursor, code, line_number, mode}, from, state)
  end

  @impl true
  def handle_call(
        {:run_at_cursor, code, line_number, mode},
        from,
        %{file_path: _file_path} = state
      ) do
    opts = if mode == :block, do: [block_mode: true], else: []

    with {:ok, exprs} <- parse_code(code, opts) do
      exprs_at =
        exprs
        |> Enum.filter(fn %Expression{line_start: line_start, line_end: line_end} ->
          line_start <= line_number and line_end >= line_number
        end)

      mode_str = if mode == :block, do: "block", else: "expression"

      IO.puts(
        IO.ANSI.yellow() <> "Running #{mode_str} at line #{line_number}:" <> IO.ANSI.reset()
      )

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
  def handle_info(:poll, %{file_path: file_path, last_modified: nil} = state) do
    # first poll, run the code completely
    with {:ok, %{mtime: mtime}} <- File.stat(file_path),
         {:ok, current_code} <- File.read(file_path),
         {:ok, current_exprs} <- parse_code(current_code) do
      # Preamble to make argv the same as when the file is run with elixir without livescript
      preamble_code(file_path)
      |> Livescript.Executor.execute()

      Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
        executed_exprs = Livescript.Executor.execute(current_exprs)
        {:done_executing, executed_exprs, mtime}
      end)

      {:noreply, %{state | last_modified: mtime}}
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

          case parse_code(next_code) do
            {:ok, next_exprs} ->
              {common_exprs, _rest_exprs, _rest_next_exprs} =
                split_at_diff(
                  Enum.map(state.executed_exprs, & &1.quoted),
                  Enum.map(next_exprs, & &1.quoted)
                )

              common_exprs = Enum.take(next_exprs, length(common_exprs))
              rest_next_exprs = Enum.drop(next_exprs, length(common_exprs))

              Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
                executed_exprs = Livescript.Executor.execute(rest_next_exprs)
                {:done_executing, common_exprs ++ executed_exprs, mtime}
              end)

              {:noreply, %{state | last_modified: mtime}}

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

    with {:ok, {_, _, quoted}} <- Code.string_to_quoted(code),
         {:ok, {_, _, precise_quoted}} <- Code.string_to_quoted(code, parse_opts) do
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

defmodule Livescript.TCP do
  require Logger

  def server() do
    file_path = :sys.get_state(Livescript).file_path
    port = find_available_port(13137..13237)
    port_file = get_port_file_path(file_path)

    # Write port to temp file
    File.mkdir_p!(Path.dirname(port_file))
    File.write!(port_file, "#{port}")

    Process.register(self(), Livescript.TCP)

    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    IO.puts(IO.ANSI.yellow() <> "Listening for commands on port #{port}" <> IO.ANSI.reset())

    accept_connections(socket)
  end

  # Helper to find an available port
  defp find_available_port(port_range) do
    Enum.find(port_range, fn port ->
      case :gen_tcp.listen(port, [:binary]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _} ->
          false
      end
    end) || raise "No available ports in range #{inspect(port_range)}"
  end

  # Generate unique temp file path for port
  defp get_port_file_path(file_path) do
    hash = :crypto.hash(:md5, file_path) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "livescript_#{hash}.port")
  end

  defp accept_connections(socket) do
    {:ok, client} = :gen_tcp.accept(socket)

    {:ok, pid} =
      Task.Supervisor.start_child(Livescript.TaskSupervisor, fn -> handle_client(client) end)

    :gen_tcp.controlling_process(client, pid)
    accept_connections(socket)
  end

  defp handle_client(socket) do
    with {:ok, data} <- receive_complete_message(socket, ""),
         {:ok, decoded} <- try_json_decode(data),
         {:ok, result} <- handle_command(decoded),
         {:ok, encoded_response} <- try_json_encode(result) do
      :gen_tcp.send(socket, "{\"success\": true, \"result\": #{encoded_response}}")
    else
      {:error, error} ->
        encoded_error =
          try do
            :json.encode(error)
          rescue
            _ -> :json.encode(%{type: "internal_error", details: inspect(error)})
          end

        :gen_tcp.send(socket, "{\"success\": false, \"error\": #{encoded_error}}")
    end

    :gen_tcp.close(socket)
  end

  # Recursively receive data until we get a complete message ending in newline
  defp receive_complete_message(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        new_acc = acc <> data

        if String.ends_with?(new_acc, "\n") do
          {:ok, String.trim(new_acc)}
        else
          receive_complete_message(socket, new_acc)
        end

      {:error, :closed} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, "Error receiving data: #{inspect(reason)}"}
    end
  end

  defp try_json_decode(data) do
    try do
      {:ok, data |> :json.decode()}
    rescue
      error -> {:error, "Unable to decode JSON: #{inspect(error)} on data: #{inspect(data)}"}
    end
  end

  defp try_json_encode(data) do
    try do
      {:ok, data |> :json.encode()}
    rescue
      error -> {:error, "Unable to encode JSON: #{inspect(error)} on data: #{inspect(data)}"}
    end
  end

  defp handle_command(%{"command" => "run_after_cursor", "code" => code, "line" => line}) do
    case Livescript.run_after_cursor(code, line) do
      :ok -> {:ok, true}
      error -> error
    end
  end

  defp handle_command(%{"command" => "run_after_cursor", "line" => line}) do
    case Livescript.run_after_cursor(line) do
      :ok -> {:ok, true}
      error -> error
    end
  end

  defp handle_command(%{
         "command" => "run_at_cursor",
         "code" => code,
         "line" => line,
         "mode" => mode
       }) do
    mode_atom = String.to_existing_atom(mode)

    case Livescript.run_at_cursor(code, line, mode_atom) do
      :ok -> {:ok, true}
      error -> error
    end
  end

  defp handle_command(%{"command" => "run_at_cursor", "line" => line, "mode" => mode}) do
    mode_atom = String.to_existing_atom(mode)

    case Livescript.run_at_cursor(line, mode_atom) do
      :ok -> {:ok, true}
      error -> error
    end
  end

  defp handle_command(%{"command" => "verify_connection", "filepath" => filepath}) do
    current_file = :sys.get_state(Livescript) |> Map.get(:file_path)

    {:ok,
     %{
       "connected" => Path.expand(filepath) == Path.expand(current_file),
       "current_file" => current_file
     }}
  end

  defp handle_command(%{"command" => "parse_code", "code" => code, "block_mode" => block_mode}) do
    case Livescript.parse_code(code, block_mode: block_mode) do
      {:ok, exprs} ->
        {:ok,
         exprs
         |> Enum.map(fn expr ->
           %{
             expr: expr.code,
             line_start: expr.line_start,
             line_end: expr.line_end
           }
         end)}

      {:error, error} ->
        {:error,
         %{
           type: "parse_error",
           details: inspect(error)
         }}
    end
  end

  defp handle_command(command) do
    Logger.info("Received unknown command: #{inspect(command)}")
    {:error, %{type: "unknown_command", details: "Command not recognized"}}
  end
end
