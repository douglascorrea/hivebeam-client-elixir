defmodule HivebeamClient do
  @moduledoc false

  alias HivebeamClient.Session

  @type start_opts :: keyword()

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    owner = Keyword.get(opts, :owner, self())
    Session.start_link(Keyword.put(opts, :owner, owner))
  end

  @spec create_session(GenServer.server(), map()) :: {:ok, map()} | {:error, Exception.t()}
  def create_session(client, attrs \\ %{}) when is_map(attrs),
    do: Session.create_session(client, attrs)

  @spec attach(GenServer.server(), String.t() | keyword()) ::
          {:ok, map()} | {:error, Exception.t()}
  def attach(client, arg), do: Session.attach(client, arg)

  @spec prompt(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Exception.t()}
  def prompt(client, request_id, text, opts \\ []),
    do: Session.prompt(client, request_id, text, opts)

  @spec cancel(GenServer.server(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def cancel(client, opts \\ []), do: Session.cancel(client, opts)

  @spec approve(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Exception.t()}
  def approve(client, approval_ref, decision, opts \\ []),
    do: Session.approve(client, approval_ref, decision, opts)

  @spec close(GenServer.server(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def close(client, opts \\ []), do: Session.close(client, opts)

  @spec fetch_events(GenServer.server(), integer(), pos_integer()) ::
          {:ok, map()} | {:error, Exception.t()}
  def fetch_events(client, after_seq, limit), do: Session.fetch_events(client, after_seq, limit)
end
