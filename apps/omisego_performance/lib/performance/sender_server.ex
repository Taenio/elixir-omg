defmodule OmiseGO.Performance.SenderServer do
  @moduledoc """
  The SenderServer process synchronously sends requested number of transactions to the blockchain server.
  """

  # Waiting time (in milliseconds) before unsuccessful Tx submittion is retried.
  @tx_retry_waiting_time_ms 333

  require Logger
  use GenServer

  defmodule LastTx do
    @moduledoc """
    Submodule defines structure to keep last transaction sent by sender remembered fo the next submission.
    """
    defstruct [:blknum, :txindex, :oindex, :amount]
    @type t :: %__MODULE__{blknum: integer, txindex: integer, oindex: integer, amount: integer}
  end

  @doc """
  Defines a structure for the State of the server.
  """
  defstruct [
    # increasing number to ensure sender's deposit is accepted, @seealso @doc to :init
    :seqnum,
    :ntx_to_send,
    :spender,
    # {blknum, txindex, oindex, amount}, @see %LastTx above
    :last_tx
  ]

  @opaque state :: %__MODULE__{seqnum: integer, ntx_to_send: integer, spender: map, last_tx: LastTx.t()}

  @doc """
  Starts the process.
  """
  @spec start_link({seqnum :: integer, ntx_to_send :: integer}) :: {:ok, pid}
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Initializes the SenderServer process, register it into the Registry and schedules handle_info call.
  Assumptions:
    * Senders are assigned sequential positive int starting from 1, senders are initialized in order of seqnum.
      This ensures all senders' deposits are accepted.
  """
  @spec init({seqnum :: integer, ntx_to_send :: integer}) :: {:ok, init_state :: __MODULE__.state()}
  def init({seqnum, ntx_to_send}) do
    Logger.debug(fn -> "[#{seqnum}] +++ init/1 called with requests: '#{ntx_to_send}' +++" end)

    spender = generate_participant_address()
    Logger.debug(fn -> "[#{seqnum}]: Address #{Base.encode64(spender.addr)}" end)

    deposit_value = 10 * ntx_to_send
    owner_enc = "0x" <> Base.encode16(spender.addr, case: :lower)
    :ok = OmiseGO.API.State.deposit([%{owner: owner_enc, amount: deposit_value, blknum: seqnum}])

    Logger.debug(fn -> "[#{seqnum}]: Deposited #{deposit_value} OMG" end)

    send(self(), :do)
    {:ok, init_state(seqnum, ntx_to_send, spender)}
  end

  @doc """
  Submits transaction then schedules call to itself if more left.
  Otherwise unregisters from the Registry and stops.
  """
  @spec handle_info(:do, state :: __MODULE__.state) :: {:noreply, new_state :: __MODULE__.state} | {:stop, :normal, nil}
  def handle_info(:do, %__MODULE__{ntx_to_send: 0} = state) do
    Logger.debug(fn -> "[#{state.seqnum}] +++ Stoping... +++" end)

    %__MODULE__{seqnum: seqnum, ntx_to_send: ntx_to_send, last_tx: %LastTx{blknum: blknum, txindex: txindex}} = state
    OmiseGO.Performance.SenderManager.sender_stats(seqnum, blknum, txindex, ntx_to_send)
    OmiseGO.Performance.SenderManager.sender_completed(state.seqnum)
    {:stop, :normal, state}
  end

  def handle_info(:do, %__MODULE__{} = state) do
    newstate = case submit_tx(state) do
      {:ok, newblknum, newtxindex, newvalue} ->
        send(self(), :do)
        state |> next_state(newblknum, newtxindex, newvalue)

      :retry ->
        Process.send_after(self(), :do, @tx_retry_waiting_time_ms)
        state
    end
    {:noreply, newstate}
  end

  @doc """
  Submits new transaction to the blockchain server.
  """
  @spec submit_tx(__MODULE__.state)
  :: {result :: tuple, blknum :: pos_integer, txindex :: pos_integer, newamount :: pos_integer}
  def submit_tx(%__MODULE__{seqnum: seqnum, spender: spender, last_tx: last_tx} = state) do
    alias OmiseGO.API.State.Transaction

    #random_sleep(seqnum)

    to_spend = 9
    newamount = last_tx.amount - to_spend
    recipient = generate_participant_address()
    Logger.debug(fn -> "[#{seqnum}]: Sending Tx to new owner #{Base.encode64(recipient.addr)}, left: #{newamount}" end)

    tx =
      [{last_tx.blknum, last_tx.txindex, last_tx.oindex}]
      |> Transaction.new([{spender.addr, newamount}, {recipient.addr, to_spend}], 0)
      |> Transaction.sign(spender.priv, <<>>)
      |> Transaction.Signed.encode()

<<<<<<< 5a03a3300d88cd0ad20e66ffc9c880b63431833f
    result = OmiseGO.API.submit(Base.encode16(tx))

    case result do
      {:error, reason} ->
        Logger.debug(fn -> "[#{seqnum}]: Transaction submission has failed, reason: #{reason}" end)
        {:error, reason}
=======
      result = OmiseGO.API.submit(tx)
      case result do
        {:error, :too_many_transactions_in_block} ->
          Logger.info(fn ->
            "[#{seqnum}]: Transaction submittion will be retried, block #{last_tx.blknum} is full." end)
          :retry

        {:error,  reason} ->
          Logger.debug(fn ->
            "[#{seqnum}]: Transaction submission has failed, reason: #{reason}" end)
          {:error, reason}
>>>>>>> Integrating senders registry and wait_for into single SenderManager module

        {:ok, _, blknum, txindex} ->
          Logger.debug(fn ->
            "[#{seqnum}]: Transaction submitted successfully {#{blknum}, #{txindex}, #{newamount}}" end)

          if blknum > last_tx.blknum, do:
            OmiseGO.Performance.SenderManager.sender_stats(seqnum, last_tx.blknum, last_tx.txindex, state.ntx_to_send)

          {:ok, blknum, txindex, newamount}
      end
  end

  @doc """
  Generates participant private key and address
  """
  @spec generate_participant_address() :: %{priv: <<_::256>>, addr: <<_::160>>}
  def generate_participant_address do
    alias OmiseGO.API.Crypto
    {:ok, priv} = Crypto.generate_private_key()
    {:ok, pub} = Crypto.generate_public_key(priv)
    {:ok, addr} = Crypto.generate_address(pub)
    %{priv: priv, addr: addr}
  end

  # Generates module's initial state
  @spec init_state(seqnum :: pos_integer, nreq :: pos_integer, spender :: %{priv: <<_::256>>, addr: <<_::160>>}) ::
          __MODULE__.state()
  defp init_state(seqnum, nreq, spender) do
    %__MODULE__{
      seqnum: seqnum,
      ntx_to_send: nreq,
      spender: spender,
      last_tx: %LastTx{
        # initial state takes deposited value, put there on :init
        blknum: seqnum,
        txindex: 0,
        oindex: 0,
        amount: 10 * nreq
      }
    }
  end

  # Generates next module's state
  @spec next_state(state :: __MODULE__.state(), blknum :: pos_integer, txindex :: pos_integer, amount :: pos_integer) ::
          __MODULE__.state()
  defp next_state(%__MODULE__{ntx_to_send: ntx_to_send} = state, blknum, txindex, amount) do
    %__MODULE__{
      state
      | ntx_to_send: ntx_to_send - 1,
        last_tx: %LastTx{
          state.last_tx
          | blknum: blknum,
            txindex: txindex,
            amount: amount
        }
    }
  end

  # Helper function to test interaction between Performance modules
  defp random_sleep(seqnum) do
    Logger.debug(fn -> "[#{seqnum}]: Need some sleep" end)
    [500, 800, 1000, 1300] |> Enum.random |> Process.sleep
  end
end
