defmodule Tay.Engine.Lifecycle.Operation do
  @moduledoc """
  Pure lifecycle-operation transitions and caller-outcome classification.
  Lifecycle owns effects, token/sender correlation, and the operation slot.
  Expiring an in-progress effect detaches its caller but does not complete it.
  """
  alias Tay.Error
  @enforce_keys [:token, :kind, :owner, :deadline, :phase, :cancel_flag]
  defstruct [
    :token,
    :kind,
    :owner,
    :deadline,
    :phase,
    :cancel_flag,
    :from,
    :timer,
    :driver,
    :monitor,
    :stats,
    :terminal_retention,
    :expected_source
  ]

  @type t :: %__MODULE__{}
  @transitions %{
    {:stop, :draining, :drained} => :closing,
    {:restart, :draining, :drained} => :closing,
    {:compact, :draining, :drained} => :compacting,
    {:stop, :draining, :close} => :closing,
    {:restart, :draining, :close} => :closing,
    {:compact, :compacting, :close} => :closing,
    {:compact, :compacting, :offline_fallback} => :draining,
    {:restart, :closing, :starting} => :starting,
    {:compact, :closing, :starting} => :starting
  }

  @doc "Advances only a permitted phase; a late drain cannot authorize effects."
  @spec advance(t(), atom(), integer()) :: {:ok, t()} | {:error, atom()}
  def advance(%__MODULE__{} = operation, event, now) do
    case Map.fetch(@transitions, {operation.kind, operation.phase, event}) do
      {:ok, _phase} when event == :drained and now >= operation.deadline ->
        {:error, :draining_deadline}

      {:ok, phase} ->
        {:ok, %{operation | phase: phase}}

      :error ->
        {:error, :invalid_operation_transition}
    end
  end

  @doc "Consumes a deadline event without mistaking caller expiry for effect completion."
  @spec expire(t()) :: {:finish, {:error, %Error{}}} | {:pending, t(), tuple() | nil}
  def expire(%__MODULE__{phase: :draining} = operation),
    do: {:finish, {:error, Error.new(:timeout, :draining, nil, operation.kind)}}

  def expire(%__MODULE__{} = operation) do
    reply = {:error, Error.new(:unknown_outcome, :lifecycle_in_progress, nil, operation.kind)}
    notification = if operation.from, do: {operation.from, reply}, else: nil
    {:pending, %{operation | from: nil}, notification}
  end

  @doc "Opaque failures after effects start have an unknown result, not a safe retry."
  @spec failure(t(), term()) :: %Error{}
  def failure(%__MODULE__{} = operation, reason) do
    kind = if operation.phase == :draining, do: :unavailable, else: :unknown_outcome
    Error.new(kind, reason, nil, operation.kind)
  end
end
