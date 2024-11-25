defmodule Mix.Tasks.Livescript do
  use Mix.Task

  def run(["run", exs_path | _]) do
    qualified_exs_path = Path.absname(exs_path) |> Path.expand()
    Logger.put_module_level(Livescript, :info)
    code = File.read!(qualified_exs_path)

    Task.async(fn ->
      preamble_exprs = Livescript.preamble_code(qualified_exs_path)
      Livescript.execute_code(preamble_exprs)
      {:ok, exprs} = Livescript.parse_code(code)
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
    Livescript.TCP.start_link()
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
    GenServer.call(__MODULE__, {:run_at_cursor, line_number})
  end

  def run_at_cursor(code, line_number) when is_integer(line_number) and is_binary(code) do
    GenServer.call(__MODULE__, {:run_at_cursor, code, line_number})
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
  def handle_call({:run_after_cursor, code, line_number}, _from, %{file_path: _file_path} = state) do
    with {:ok, exprs} <- parse_code(code) do
      exprs_after =
        exprs
        |> Enum.filter(fn %Expression{line_start: min_line} ->
          min_line >= line_number
        end)

      IO.puts(IO.ANSI.yellow() <> "Running code after line #{line_number}:" <> IO.ANSI.reset())
      _executed_exprs = execute_code(exprs_after)
      {:reply, :ok, state}
    else
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:run_at_cursor, line_number}, from, %{file_path: file_path} = state) do
    code = File.read!(file_path)
    handle_call({:run_at_cursor, code, line_number}, from, state)
  end

  @impl true
  def handle_call({:run_at_cursor, code, line_number}, _from, %{file_path: _file_path} = state) do
    with {:ok, exprs} <- parse_code(code) do
      exprs_at =
        exprs
        |> Enum.filter(fn %Expression{line_start: line_start, line_end: line_end} ->
          line_start <= line_number and line_end >= line_number
        end)

      IO.puts(IO.ANSI.yellow() <> "Running code at line #{line_number}:" <> IO.ANSI.reset())
      _executed_exprs = execute_code(exprs_at)
      {:reply, :ok, state}
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
      |> execute_code()

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

          case parse_code(next_code) do
            {:ok, next_exprs} ->
              {common_exprs, _rest_exprs, _rest_next_exprs} =
                split_at_diff(state.executed_exprs, Enum.map(next_exprs, & &1.quoted))

              # Logger.info("Executed exprs: #{Macro.to_string(state.executed_exprs)}")
              # Logger.info("Common exprs: #{Macro.to_string(common_exprs)}")
              # Logger.info("Next exprs: #{Macro.to_string(rest_next_exprs)}")

              rest_next_exprs =
                next_exprs
                |> Enum.drop(length(common_exprs))

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

  def call_home_macro(expr) do
    quote do
      send(
        :erlang.list_to_pid(unquote(:erlang.pid_to_list(self()))),
        {:__livescript__, unquote(expr)}
      )
    end
  end

  def execute_code(exprs) do
    num_exprs = length(exprs)

    exprs
    |> Enum.with_index()
    |> Enum.take_while(fn {%Expression{} = expr, index} ->
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

        if is_last do
          do_execute_code("", print_result: "livescript_result__")
        end

        true
      else
        false
      end
    end)
    |> Enum.map(fn {expr, _} -> expr.quoted end)
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

  @doc """
  Parse the code and return a list of expressions with the line range.

  It parses the code twice to get the precise line range (see [string_to_quoted/2](https://hexdocs.pm/elixir/1.17.2/Code.html#quoted_to_algebra/2-formatting-considerations)).
  """
  def parse_code(code) do
    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      unescape: false
    ]

    with {:ok, {_, _, quoted}} <- Code.string_to_quoted(code),
         {:ok, {_, _, precise_quoted}} <- Code.string_to_quoted(code, opts) do
      exprs =
        Enum.zip(quoted, precise_quoted)
        |> Enum.map(fn {quoted, precise_quoted} ->
          {line_start, line_end} = line_range(precise_quoted)

          code =
            code
            |> String.split("\n")
            |> Enum.slice(line_start - 1, line_end - line_start + 1)
            |> Enum.join("\n")

          %Livescript.Expression{
            quoted: quoted,
            code: code,
            line_start: line_start,
            line_end: line_end
          }
        end)

      {:ok, exprs}
    end
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
end

defmodule Livescript.TCP do
  use GenServer
  require Logger

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    file_path = :sys.get_state(Livescript).file_path
    port = find_available_port(13137..13237)
    port_file = get_port_file_path(file_path)

    # Write port to temp file
    File.mkdir_p!(Path.dirname(port_file))
    File.write!(port_file, "#{port}")

    IO.puts(IO.ANSI.yellow() <> "Listening for commands on port #{port}" <> IO.ANSI.reset())

    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    spawn_link(fn -> accept_connections(socket) end)
    {:ok, %{port: port, port_file: port_file}}
  end

  def terminate(_reason, %{port_file: port_file}) do
    if port_file, do: File.rm(port_file)
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
    spawn_link(fn -> handle_client(client) end)
    accept_connections(socket)
  end

  defp handle_client(socket) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0),
         {:ok, decoded} <- try_json_decode(data),
         response <- handle_command(decoded),
         {:ok, encoded_response} <- try_json_encode(response) do
      :gen_tcp.send(socket, "{\"success\": true, \"result\": #{encoded_response}}")
    else
      {:error, x} ->
        Logger.error("Error handling message: #{inspect(x)}")
        :gen_tcp.send(socket, "{\"success\": false, \"error\": \"#{inspect(x)}\"}")
    end

    :gen_tcp.close(socket)
  end

  defp try_json_decode(data) do
    try do
      {:ok, data |> :json.decode()}
    rescue
      _ -> {:error, "Unable to decode JSON: #{inspect(data)}"}
    end
  end

  defp try_json_encode(data) do
    try do
      {:ok, data |> :json.encode()}
    rescue
      _ -> {:error, "Unable to encode JSON: #{inspect(data)}"}
    end
  end

  defp handle_command(%{"command" => "run_after_cursor", "code" => code, "line" => line}) do
    Livescript.run_after_cursor(code, line)
  end

  defp handle_command(%{"command" => "run_after_cursor", "line" => line}) do
    Livescript.run_after_cursor(line)
  end

  defp handle_command(%{"command" => "run_at_cursor", "code" => code, "line" => line}) do
    Livescript.run_at_cursor(code, line)
  end

  defp handle_command(%{"command" => "run_at_cursor", "line" => line}) do
    Livescript.run_at_cursor(line)
  end

  defp handle_command(%{"command" => "verify_connection", "filepath" => filepath}) do
    current_file = :sys.get_state(Livescript) |> Map.get(:file_path)

    %{
      "connected" => Path.expand(filepath) == Path.expand(current_file),
      "current_file" => current_file
    }
  end

  defp handle_command(%{"command" => "parse_code", "code" => code}) do
    case Livescript.parse_code(code) do
      {:ok, exprs} ->
        exprs
        |> Enum.map(fn expr ->
          %{
            expr: expr.code,
            line_start: expr.line_start,
            line_end: expr.line_end
          }
        end)

      {:error, _} ->
        nil
    end
  end

  defp handle_command(command) do
    Logger.info("Received unknown command: #{inspect(command)}")
  end
end
