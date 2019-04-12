# Copyright 2018 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.Watcher.ExitProcessor do
  @moduledoc """
  Imperative shell here, for functional core and more info see `OMG.Watcher.ExitProcessor.Core`

  NOTE: Note that all calls return `db_updates` and relay on the caller to do persistence.
  """

  alias OMG.Block
  alias OMG.DB
  alias OMG.Eth
  alias OMG.State
  alias OMG.State.Transaction
  alias OMG.Utxo
  # NOTE: future of using `ExitProcessor.Request` struct not certain, see that module for details
  alias OMG.Watcher.ExitProcessor
  alias OMG.Watcher.ExitProcessor.Core
  alias OMG.Watcher.ExitProcessor.InFlightExitInfo
  alias OMG.Watcher.ExitProcessor.StandardExitChallenge
  alias OMG.Watcher.Recorder

  use OMG.Utils.LoggerExt
  require Utxo

  ### Client

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Accepts events and processes them in the state - new exits are tracked.
  Returns `db_updates`
  """
  def new_exits(exits) do
    GenServer.call(__MODULE__, {:new_exits, exits})
  end

  @doc """
  Accepts events and processes them in the state - new in flight exits are tracked.
  Returns `db_updates`
  """
  def new_in_flight_exits(in_flight_exit_started_events) do
    GenServer.call(__MODULE__, {:new_in_flight_exits, in_flight_exit_started_events})
  end

  @doc """
  Accepts events and processes them in the state - finalized exits are untracked _if valid_ otherwise raises alert
  Returns `db_updates`
  """
  def finalize_exits(finalizations) do
    GenServer.call(__MODULE__, {:finalize_exits, finalizations})
  end

  @doc """
  Accepts events and processes them in the state - new piggybacks are tracked, if invalid raises an alert
  Returns `db_updates`
  """
  def piggyback_exits(piggybacks) do
    GenServer.call(__MODULE__, {:piggyback_exits, piggybacks})
  end

  @doc """
  Accepts events and processes them in the state - challenged exits are untracked
  Returns `db_updates`
  """
  def challenge_exits(challenges) do
    GenServer.call(__MODULE__, {:challenge_exits, challenges})
  end

  @doc """
  Accepts events and processes them in the state.
  Competitors are stored for future use(i.e. to challenge an in flight exit).
  Returns `db_updates`
  """
  def new_ife_challenges(challenges) do
    GenServer.call(__MODULE__, {:new_ife_challenges, challenges})
  end

  @doc """
  Accepts events and processes them in state.
  Returns `db_updates`
  """
  def respond_to_in_flight_exits_challenges(responds) do
    GenServer.call(__MODULE__, {:respond_to_in_flight_exits_challenges, responds})
  end

  @doc """
  Accepts events and processes them in state.
  Challenged piggybacks are forgotten.
  Returns `db_updates`
  """
  def challenge_piggybacks(challenges) do
    GenServer.call(__MODULE__, {:challenge_piggybacks, challenges})
  end

  @doc """
    Accepts events and processes them in state - finalized outputs are applied to the state.
    Returns `db_updates`
  """
  def finalize_in_flight_exits(finalizations) do
    GenServer.call(__MODULE__, {:finalize_in_flight_exits, finalizations})
  end

  @doc """
  Checks validity of all exit-related events and returns the list of actionable items.
  Works with `OMG.State` to discern validity.

  This function may also update some internal caches to make subsequent calls not redo the work,
  but under unchanged conditions, it should have unchanged behavior from POV of an outside caller.
  """
  def check_validity do
    GenServer.call(__MODULE__, :check_validity)
  end

  @doc """
  Returns a map of requested in flight exits, where keys are IFE hashes and values are IFES
  If given empty list of hashes, all IFEs are returned.
  """
  @spec get_active_in_flight_exits() :: {:ok, %{binary() => InFlightExitInfo.t()}}
  def get_active_in_flight_exits do
    GenServer.call(__MODULE__, :get_active_in_flight_exits)
  end

  @doc """
  Returns all information required to produce a transaction to the root chain contract to present a competitor for
  a non-canonical in-flight exit
  """
  @spec get_competitor_for_ife(binary()) :: {:ok, Core.competitor_data_t()} | {:error, :competitor_not_found}
  def get_competitor_for_ife(txbytes) do
    GenServer.call(__MODULE__, {:get_competitor_for_ife, txbytes})
  end

  @doc """
  Returns all information required to produce a transaction to the root chain contract to present a proof of canonicity
  for a challenged in-flight exit
  """
  @spec prove_canonical_for_ife(binary()) :: {:ok, Core.prove_canonical_data_t()} | {:error, :canonical_not_found}
  def prove_canonical_for_ife(txbytes) do
    GenServer.call(__MODULE__, {:prove_canonical_for_ife, txbytes})
  end

  @spec get_input_challenge_data(Transaction.Signed.tx_bytes(), Transaction.input_index_t()) ::
          {:ok, Core.input_challenge_data()} | {:error, Core.piggyback_challenge_data_error()}
  def get_input_challenge_data(txbytes, input_index) do
    GenServer.call(__MODULE__, {:get_input_challenge_data, txbytes, input_index})
  end

  @spec get_output_challenge_data(Transaction.Signed.tx_bytes(), Transaction.input_index_t()) ::
          {:ok, Core.output_challenge_data()} | {:error, Core.piggyback_challenge_data_error()}
  def get_output_challenge_data(txbytes, output_index) do
    GenServer.call(__MODULE__, {:get_output_challenge_data, txbytes, output_index})
  end

  @doc """
  Returns challenge for an exit
  """
  @spec create_challenge(Utxo.Position.t()) ::
          {:ok, StandardExitChallenge.t()} | {:error, :utxo_not_spent | :exit_not_found}
  def create_challenge(exiting_utxo_pos) do
    GenServer.call(__MODULE__, {:create_challenge, exiting_utxo_pos})
  end

  ### Server

  use GenServer

  def init(:ok) do
    {:ok, db_exits} = DB.exit_infos()
    {:ok, db_ifes} = DB.in_flight_exits_info()
    {:ok, db_competitors} = DB.competitors_info()

    sla_margin = Application.fetch_env!(:omg_watcher, :exit_processor_sla_margin)

    processor = Core.init(db_exits, db_ifes, db_competitors, sla_margin)

    {:ok, _} = Recorder.start_link(%Recorder{name: __MODULE__.Recorder, parent: self()})

    _ = Logger.info("Initializing with: #{inspect(processor)}")
    processor
  end

  def handle_call({:new_exits, exits}, _from, state) do
    _ = if not Enum.empty?(exits), do: Logger.info("Recognized exits: #{inspect(exits)}")

    exit_contract_statuses =
      Enum.map(exits, fn %{exit_id: exit_id} ->
        {:ok, result} = Eth.RootChain.get_standard_exit(exit_id)
        result
      end)

    {new_state, db_updates} = Core.new_exits(state, exits, exit_contract_statuses)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:new_in_flight_exits, events}, _from, state) do
    _ = if not Enum.empty?(events), do: Logger.info("Recognized in-flight exits: #{inspect(events)}")

    ife_contract_statuses =
      Enum.map(
        events,
        fn %{call_data: %{in_flight_tx: bytes}} ->
          {:ok, contract_ife_id} = Eth.RootChain.get_in_flight_exit_id(bytes)
          {:ok, {timestamp, _, _, _, _}} = Eth.RootChain.get_in_flight_exit(contract_ife_id)
          {timestamp, contract_ife_id}
        end
      )

    {new_state, db_updates} = Core.new_in_flight_exits(state, events, ife_contract_statuses)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:finalize_exits, exits}, _from, state) do
    _ = if not Enum.empty?(exits), do: Logger.info("Recognized finalizations: #{inspect(exits)}")

    exits =
      exits
      |> Enum.map(fn %{exit_id: exit_id} ->
        {:ok, {_, _, _, utxo_pos}} = Eth.RootChain.get_standard_exit(exit_id)
        Utxo.Position.decode!(utxo_pos)
      end)

    {:ok, db_updates_from_state, validities} = State.exit_utxos(exits)
    {new_state, event_triggers, db_updates} = Core.finalize_exits(state, validities)

    :ok = OMG.InternalEventBus.broadcast("events", {:emit_events, event_triggers})

    {:reply, {:ok, db_updates ++ db_updates_from_state}, new_state}
  end

  def handle_call({:piggyback_exits, exits}, _from, state) do
    _ = if not Enum.empty?(exits), do: Logger.info("Recognized piggybacks: #{inspect(exits)}")
    {new_state, db_updates} = Core.new_piggybacks(state, exits)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:challenge_exits, exits}, _from, state) do
    _ = if not Enum.empty?(exits), do: Logger.info("Recognized challenges: #{inspect(exits)}")
    {new_state, db_updates} = Core.challenge_exits(state, exits)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:new_ife_challenges, challenges}, _from, state) do
    _ = if not Enum.empty?(challenges), do: Logger.info("Recognized ife challenges: #{inspect(challenges)}")
    {new_state, db_updates} = Core.new_ife_challenges(state, challenges)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:challenge_piggybacks, challenges}, _from, state) do
    _ = if not Enum.empty?(challenges), do: Logger.info("Recognized piggyback challenges: #{inspect(challenges)}")
    {new_state, db_updates} = Core.challenge_piggybacks(state, challenges)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:respond_to_in_flight_exits_challenges, responds}, _from, state) do
    _ = if not Enum.empty?(responds), do: Logger.info("Recognized response to IFE challenge: #{inspect(responds)}")
    {new_state, db_updates} = Core.respond_to_in_flight_exits_challenges(state, responds)
    {:reply, {:ok, db_updates}, new_state}
  end

  def handle_call({:finalize_in_flight_exits, finalizations}, _from, state) do
    _ = if not Enum.empty?(finalizations), do: Logger.info("Recognized ife finalizations: #{inspect(finalizations)}")
    {:ok, state, db_updates} = Core.finalize_in_flight_exits(state, finalizations)
    {:reply, {:ok, db_updates}, state}
  end

  def handle_call(:check_validity, _from, state) do
    new_state = update_with_ife_txs_from_blocks(state)

    response =
      %ExitProcessor.Request{}
      |> fill_request_with_data(new_state)
      |> Core.check_validity(new_state)

    {:reply, response, new_state}
  end

  def handle_call(:get_active_in_flight_exits, _from, state),
    do: {:reply, {:ok, Core.get_active_in_flight_exits(state)}, state}

  def handle_call({:get_competitor_for_ife, txbytes}, _from, state) do
    # TODO: run_status_gets and getting all non-existent UTXO positions imaginable can be optimized out heavily
    #       only the UTXO positions being inputs to `txbytes` must be looked at, but it becomes problematic as
    #       txbytes can be invalid so we'd need a with here...
    competitor_result =
      %ExitProcessor.Request{}
      |> fill_request_with_data(state)
      |> Core.get_competitor_for_ife(state, txbytes)

    {:reply, competitor_result, state}
  end

  def handle_call({:prove_canonical_for_ife, txbytes}, _from, state) do
    # TODO: same comment as above in get_competitor_for_ife
    canonicity_result =
      %ExitProcessor.Request{}
      |> fill_request_with_data(state)
      |> Core.prove_canonical_for_ife(txbytes)

    {:reply, canonicity_result, state}
  end

  def handle_call({:get_input_challenge_data, txbytes, input_index}, _from, state) do
    response =
      %ExitProcessor.Request{}
      |> fill_request_with_data(state)
      |> Core.get_input_challenge_data(state, txbytes, input_index)

    {:reply, response, state}
  end

  def handle_call({:get_output_challenge_data, txbytes, output_index}, _from, state) do
    new_state = update_with_ife_txs_from_blocks(state)

    response =
      %ExitProcessor.Request{}
      |> fill_request_with_data(new_state)
      |> Core.get_output_challenge_data(new_state, txbytes, output_index)

    {:reply, response, new_state}
  end

  def handle_call({:create_challenge, Utxo.position(blknum, _txindex, _oindex) = exiting_utxo_pos}, _from, state) do
    with spending_blknum_response <- exiting_utxo_pos |> Utxo.Position.to_db_key() |> OMG.DB.spent_blknum(),
         {:ok, hashes} <- OMG.DB.block_hashes([blknum]),
         {:ok, [block]} <- OMG.DB.blocks(hashes),
         {:ok, raw_spending_proof, exit_info, exit_txbytes} <-
           Core.get_challenge_data(spending_blknum_response, exiting_utxo_pos, block, state),
         encoded_utxo_pos <- Utxo.Position.encode(exiting_utxo_pos),
         {:ok, exit_id} <- OMG.Eth.RootChain.get_standard_exit_id(exit_txbytes, encoded_utxo_pos) do
      # TODO: we're violating the shell/core pattern here, refactor!
      spending_proof =
        case raw_spending_proof do
          raw_blknum when is_number(raw_blknum) ->
            {:ok, hashes} = OMG.DB.block_hashes([raw_blknum])
            {:ok, [spending_block]} = OMG.DB.blocks(hashes)
            Block.from_db_value(spending_block)

          signed_tx ->
            signed_tx
        end

      {:reply, {:ok, Core.create_challenge(exit_info, spending_proof, exiting_utxo_pos, exit_id)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  # based on the exits being processed, fills the request structure with data required to process queries
  @spec fill_request_with_data(ExitProcessor.Request.t(), Core.t()) :: ExitProcessor.Request.t()
  defp fill_request_with_data(request, state) do
    request
    |> run_status_gets()
    |> Core.determine_utxo_existence_to_get(state)
    |> get_utxo_existence()
    |> Core.determine_spends_to_get(state)
    |> get_spending_blocks()
  end

  # based on in-flight exiting transactions, updates the state with witnesses of those transactions' inclusions in block
  @spec update_with_ife_txs_from_blocks(Core.t()) :: Core.t()
  defp update_with_ife_txs_from_blocks(state) do
    %ExitProcessor.Request{}
    |> run_status_gets()
    # To find if IFE was included, see first if its inputs were spent.
    |> Core.determine_ife_input_utxos_existence_to_get(state)
    |> get_ife_input_utxo_existence()
    # Next, check by what transactions they were spent.
    |> Core.determine_ife_spends_to_get(state)
    |> get_ife_input_spending_blocks()
    # Compare found txes with ife.tx.
    # If equal, persist information about position.
    |> Core.find_ifes_in_blocks(state)
  end

  defp run_status_gets(%ExitProcessor.Request{} = request) do
    {:ok, eth_height_now} = Eth.get_ethereum_height()
    {blknum_now, _} = State.get_status()

    _ = Logger.debug("eth_height_now: #{inspect(eth_height_now)}, blknum_now: #{inspect(blknum_now)}")
    %{request | eth_height_now: eth_height_now, blknum_now: blknum_now}
  end

  defp get_utxo_existence(%ExitProcessor.Request{utxos_to_check: positions} = request),
    do: %{request | utxo_exists_result: do_utxo_exists?(positions)}

  defp get_ife_input_utxo_existence(%ExitProcessor.Request{ife_input_utxos_to_check: positions} = request),
    do: %{request | ife_input_utxo_exists_result: do_utxo_exists?(positions)}

  defp do_utxo_exists?(positions) do
    result = positions |> Enum.map(&State.utxo_exists?/1)
    _ = Logger.debug("utxos_to_check: #{inspect(positions)}, utxo_exists_result: #{inspect(result)}")
    result
  end

  defp get_spending_blocks(%ExitProcessor.Request{spends_to_get: positions} = request),
    do: %{request | blocks_result: do_get_spending_blocks(positions)}

  defp get_ife_input_spending_blocks(%ExitProcessor.Request{ife_input_spends_to_get: positions} = request),
    do: %{request | ife_input_spending_blocks_result: do_get_spending_blocks(positions)}

  defp do_get_spending_blocks(positions) do
    blknums = positions |> Enum.map(&do_get_spent_blknum/1)
    _ = Logger.debug("spends_to_get: #{inspect(positions)}, spent_blknum_result: #{inspect(blknums)}")
    {:ok, hashes} = OMG.DB.block_hashes(blknums)
    _ = Logger.debug("hashes: #{inspect(hashes)}")
    {:ok, blocks} = OMG.DB.blocks(hashes)
    _ = Logger.debug("blocks_result: #{inspect(blocks)}")

    blocks |> Enum.map(&Block.from_db_value/1)
  end

  defp do_get_spent_blknum(position) do
    {:ok, spend_blknum} = position |> Utxo.Position.to_db_key() |> OMG.DB.spent_blknum()
    spend_blknum
  end
end
