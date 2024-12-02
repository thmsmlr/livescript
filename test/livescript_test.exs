defmodule LivescriptTest do
  use ExUnit.Case

  describe "split_at_diff" do
    test "add element" do
      first = [1, 2, 3]
      second = [1, 2, 3, 4]
      expected = {[1, 2, 3], [], [4]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "change last element" do
      first = [1, 2, 3]
      second = [1, 2, 4]
      expected = {[1, 2], [3], [4]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "remove element" do
      first = [1, 2, 3]
      second = [1, 2]
      expected = {[1, 2], [3], []}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "add element at the beginning" do
      first = [1, 2, 3]
      second = [4, 1, 2, 3]
      expected = {[], [1, 2, 3], [4, 1, 2, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "remove element at the beginning" do
      first = [1, 2, 3]
      second = [2, 3]
      expected = {[], [1, 2, 3], [2, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end

    test "change element in the middle" do
      first = [1, 2, 3]
      second = [1, 4, 3]
      expected = {[1], [2, 3], [4, 3]}
      {common, rest1, rest2} = Livescript.split_at_diff(first, second)
      assert expected == {common, rest1, rest2}
      assert common ++ rest1 == first
      assert common ++ rest2 == second
    end
  end

  describe "e2e" do
    setup do
      unique_id =
        :crypto.hash(:md5, :erlang.term_to_binary(:erlang.make_ref())) |> Base.encode16()

      script_path = Path.join(System.tmp_dir!(), "livescript_test_#{unique_id}")
      File.touch!(script_path)

      {:ok, iex_app_pid} = IEx.App.start(:normal, [])
      {:ok, livescript_app_pid} = Livescript.App.start(:normal, [script_path])

      iex_server =
        spawn_link(fn ->
          IEx.Server.run([])
          Process.sleep(:infinity)
        end)

      on_exit(fn ->
        File.rm!(script_path)
        Process.exit(iex_app_pid, :shutdown)
        Process.exit(iex_server, :shutdown)
        Process.exit(livescript_app_pid, :shutdown)
      end)

      %{script_path: script_path}
    end

    defp call_home_with(val) do
      quote do
        send(
          :erlang.list_to_pid(unquote(:erlang.pid_to_list(self()))),
          {:__livescript_test_return, unquote(val)}
        )
      end
      |> Macro.to_string()
    end

    defp get_return_value() do
      receive do
        {:__livescript_test_return, val} -> val
      after
        5000 -> raise "Timeout waiting for return value"
      end
    end

    defp update_script(script_path, code) do
      mtime = File.stat!(script_path).mtime
      File.write!(script_path, code)
      wait_for_change(script_path, mtime)
    end

    defp wait_for_change(path, mtime) do
      new_mtime = File.stat!(path).mtime

      if new_mtime == mtime do
        File.touch!(path)
        Process.sleep(30)
        wait_for_change(path, mtime)
      end
    end

    test "can run a simple script", %{script_path: script_path} do
      update_script(script_path, """
      IO.puts("Hello World")
      IO.puts("This is a test")
      #{call_home_with(:__livescript_test_ok)}
      """)

      assert get_return_value() == :__livescript_test_ok
    end

    test "can run a script with bindings", %{script_path: script_path} do
      update_script(script_path, """
      a = 1
      b = 2
      #{call_home_with(quote do: a + b)}
      """)

      assert get_return_value() == 3
    end

    test "overwrites a binding", %{script_path: script_path} do
      update_script(script_path, """
      a = 1
      b = 2
      #{call_home_with(quote do: a + b)}
      """)

      assert get_return_value() == 3

      update_script(script_path, """
      a = 1
      b = 3
      #{call_home_with(quote do: a + b)}
      """)

      assert get_return_value() == 4
    end

    test "error doesn't crash the server", %{script_path: script_path} do
      update_script(script_path, """
      a = 1
      raise "This is a test error"
      IO.inspect(a, label: "a")
      """)

      update_script(script_path, """
      a = 1
      IO.inspect(a, label: "a")
      #{call_home_with(quote do: a)}
      """)

      assert get_return_value() == 1
    end

    test "can use structs", %{script_path: script_path} do
      update_script(script_path, """
      defmodule Test do
        defstruct a: 1
      end

      t = %Test{a: 2}
      #{call_home_with(quote do: t)}
      """)

      assert %{a: 2} = get_return_value()
    end

    test "doesn't rerun stale expressions", %{script_path: script_path} do
      update_script(script_path, """
      a = 1
      #{call_home_with(quote do: a)}
      """)

      assert get_return_value() == 1

      update_script(script_path, """
      a = 1
      #{call_home_with(quote do: a)}
      b = 2
      #{call_home_with(quote do: a + b)}
      """)

      # If not true, we rerun the first expression and get 1,
      # then the second and get 3
      assert get_return_value() == 3
    end

    test "is running in same session", %{script_path: script_path} do
      update_script(script_path, """
      Process.put(:livescript_test_key, :foobar)
      #{call_home_with(:ok)}
      """)

      assert :ok = get_return_value()

      update_script(script_path, """
      #{call_home_with(quote do: Process.get(:livescript_test_key))}
      """)

      assert :foobar = get_return_value()
    end

    test "can run empty script", %{script_path: script_path} do
      update_script(script_path, "")
      update_script(script_path, "#{call_home_with(:ok)}")
      assert :ok = get_return_value()
    end
  end
end
