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

  defp handle_command(%{
         "command" => "run_at_cursor",
         "code" => code,
         "line" => line,
         "line_end" => line_end
       }) do
    case Livescript.run_at_cursor(code, line, line_end) do
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

  defp handle_command(%{"command" => "parse_code", "code" => code, "mode" => mode}) do
    with {:parse, {:ok, exprs}} <- {:parse, Livescript.parse_code(code)},
         %{executed_exprs: executed_exprs} <- Livescript.get_state() do
      exprs =
        exprs
        |> Enum.map(fn expr ->
          %{
            expr: expr.code,
            line_start: expr.line_start,
            line_end: expr.line_end,
            executed:
              Enum.any?(executed_exprs, fn executed_expr ->
                executed_expr.quoted == expr.quoted
              end)
          }
        end)

      case mode do
        "block" ->
          merged_exprs =
            exprs
            |> Enum.sort_by(& &1.line_start)
            |> Enum.reduce([], fn expr, acc ->
              case acc do
                [prev | rest] when prev.line_end + 1 == expr.line_start ->
                  merged = %{
                    expr: prev.expr <> "\n" <> expr.expr,
                    line_start: prev.line_start,
                    line_end: expr.line_end,
                    executed: prev.executed or expr.executed
                  }

                  [merged | rest]

                _ ->
                  [expr | acc]
              end
            end)
            |> Enum.reverse()

          {:ok, merged_exprs}

        "expression" ->
          {:ok, exprs}

        _ ->
          {:error, %{type: "unknown_mode", details: "`#{inspect(mode)}` mode not recognized"}}
      end
    else
      {:parse, {:error, error}} ->
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
