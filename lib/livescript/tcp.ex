defmodule Livescript.TCP do
  require Logger

  # 15 seconds in milliseconds
  @heartbeat_timeout 15_000

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
         {:ok, decoded} <- try_json_decode(data) do
      case decoded do
        %{"command" => "establish_persistent"} ->
          handle_persistent_connection(socket)
      end
    else
      {:error, error} ->
        send_error_response(socket, error)
        :gen_tcp.close(socket)
    end
  end

  defp handle_persistent_connection(socket) do
    Logger.info("Establishing persistent connection")

    # Switch to active mode for persistent connections
    :ok = :gen_tcp.send(socket, encode_response(%{type: "connection_established"}))
    :ok = :inet.setopts(socket, active: true)

    # Start heartbeat monitor
    main_pid = self()
    monitor_pid = spawn_link(fn -> monitor_heartbeat(socket, main_pid) end)

    Livescript.Broadcast.subscribe(main_pid)

    # Handle incoming messages in active mode
    persistent_connection_loop(socket, monitor_pid)
  end

  defp persistent_connection_loop(socket, monitor_pid) do
    receive do
      {:tcp, ^socket, data} ->
        Task.Supervisor.async_nolink(Livescript.TaskSupervisor, fn ->
          handle_persistent_message(socket, data, monitor_pid)
        end)

        persistent_connection_loop(socket, monitor_pid)

      {:tcp_closed, ^socket} ->
        Logger.info("Persistent connection closed by client")
        Process.exit(monitor_pid, :normal)
        :ok

      {:tcp_error, ^socket, reason} ->
        Logger.error("Persistent connection error: #{inspect(reason)}")
        Process.exit(monitor_pid, :normal)
        :gen_tcp.close(socket)
        :ok

      {:heartbeat_timeout} ->
        Logger.warning("Heartbeat timeout - closing connection")
        Process.exit(monitor_pid, :normal)
        :gen_tcp.close(socket)
        :ok

      {:broadcast, event} ->
        :gen_tcp.send(socket, encode_response(%{type: event.type, timestamp: event.timestamp}))
        persistent_connection_loop(socket, monitor_pid)
    end
  end

  defp handle_persistent_message(socket, data, monitor_pid) do
    with {:ok, decoded} <- try_json_decode(String.trim(data)) do
      case decoded do
        %{"command" => "heartbeat"} ->
          send(monitor_pid, {:heartbeat_received})
          :ok

        %{"ref" => ref} = command ->
          with {:ok, result} <- handle_command(command) do
            :gen_tcp.send(socket, encode_response(%{success: true, result: result, ref: ref}))
            :ok
          else
            {:error, error} ->
              :gen_tcp.send(socket, encode_response(%{success: false, error: error, ref: ref}))
              :ok
          end

        _ ->
          :ok
      end
    else
      {:error, error} ->
        # Include ref in error response if it was in the request
        error_response =
          case try_json_decode(String.trim(data)) do
            {:ok, %{"ref" => ref}} ->
              %{success: false, error: error, ref: ref}

            _ ->
              %{success: false, error: error}
          end

        :gen_tcp.send(socket, encode_response(error_response))
        :ok
    end
  end

  defp monitor_heartbeat(socket, main_pid) do
    receive do
      {:heartbeat_received} ->
        monitor_heartbeat(socket, main_pid)
    after
      @heartbeat_timeout ->
        send(main_pid, {:heartbeat_timeout})
    end
  end

  defp send_error_response(socket, error) do
    encoded_error =
      try do
        case try_json_encode(error) do
          {:ok, encoded} -> encoded
          {:error, _} -> :json.encode(%{type: "internal_error", details: inspect(error)})
        end
      rescue
        _ -> :json.encode(%{type: "internal_error", details: inspect(error)})
      end

    :gen_tcp.send(socket, "{\"success\": false, \"error\": #{encoded_error}}\n")
  end

  defp encode_response(data) do
    case try_json_encode(data) do
      {:ok, encoded} -> encoded <> "\n"
      {:error, _} -> "{\"error\": \"encoding_failed\"}\n"
    end
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
      {:ok, data |> :json.encode() |> :erlang.iolist_to_binary()}
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
         %{executed_exprs: executed_exprs, executing_exprs: executing_exprs} <-
           Livescript.get_state() do
      exprs =
        exprs
        |> Enum.map(fn expr ->
          status =
            cond do
              Enum.any?(executing_exprs, fn executing_expr ->
                executing_expr.quoted == expr.quoted
              end) ->
                "executing"

              Enum.any?(executed_exprs, fn executed_expr ->
                executed_expr.quoted == expr.quoted
              end) ->
                "executed"

              true ->
                "pending"
            end

          %{
            expr: expr.code,
            line_start: expr.line_start,
            line_end: expr.line_end,
            status: status
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
                    status: prev.status
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

  defp handle_command(%{"command" => "ping"}) do
    {:ok, %{type: "pong", timestamp: :os.system_time(:millisecond)}}
  end

  defp handle_command(command) do
    Logger.info("Received unknown command: #{inspect(command)}")
    {:error, %{type: "unknown_command", details: "Command not recognized"}}
  end
end
