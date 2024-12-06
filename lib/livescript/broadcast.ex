defmodule Livescript.Broadcast do
  use GenServer
  require Logger

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def subscribe(subscriber_pid) do
    GenServer.call(__MODULE__, {:subscribe, subscriber_pid})
  end

  def unsubscribe(subscriber_pid) do
    GenServer.call(__MODULE__, {:unsubscribe, subscriber_pid})
  end

  def broadcast(event) do
    GenServer.cast(__MODULE__, {:broadcast, event})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:broadcast, event}, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:broadcast, event})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end
end
