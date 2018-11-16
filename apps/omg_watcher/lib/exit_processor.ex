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
  # TODO: - handle challenge events
  # TODO: - handle finalize events. Check if a block spending finalized exit is byzantine
  # TODO: - handle finalization of invalid exits (should not remove event, turn to `is_active` and ensure it signals?)
  # TODO: - atomicity of `OMG.DB.multi_updates` (new/challenge/finalize exits, close_block, EthEventListener in gen.)
  # TODO: - merge invalid exit (1st case) test with challenge exit test (integration tests)
  # TODO: structify a tracked exit in Exit module

  @moduledoc """
  Encapsulates managing and executing the behaviors related to treating exits by the child chain and watchers
  Keeps a state of exits that are in progress, updates it with news from the root chain, compares to the
  state of the ledger (`OMG.API.State`), issues notifications as it finds suitable.

  Should manage all kinds of exits allowed in the protocol and handle the interactions between them.
  """

  alias OMG.API.EventerAPI
  alias OMG.API.State
  alias OMG.DB
  alias OMG.Eth
  alias OMG.Watcher.ExitProcessor.Core

  use OMG.API.LoggerExt

  ### Client

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def new_exits(exits) do
    GenServer.call(__MODULE__, {:new_exits, exits})
  end

  def finalize_exits(exits) do
    GenServer.call(__MODULE__, {:finalize_exits, exits})
  end

  def challenge_exits(exits) do
    GenServer.call(__MODULE__, {:challenge_exits, exits})
  end

  def check_validity do
    GenServer.call(__MODULE__, :check_validity)
  end

  ### Server

  use GenServer

  def init(:ok) do
    {:ok, db_exits} = DB.exit_infos()
    sla_margin = Application.fetch_env!(:omg_watcher, :margin_slow_validator)
    Core.init(db_exits, sla_margin)
  end

  def handle_call({:new_exits, exits}, _from, state) do
    exit_contract_statuses =
      Enum.map(exits, fn %{utxo_pos: utxo_pos} ->
        {:ok, result} = Eth.RootChain.get_exit(utxo_pos)
        result
      end)

    {new_state, db_updates} = Core.new_exits(state, exits, exit_contract_statuses)
    :ok = DB.multi_update(db_updates)
    _ = OMG.Watcher.DB.EthEvent.insert_exits(exits)
    {:reply, :ok, new_state}
  end

  def handle_call({:finalize_exits, exits}, _from, state) do
    {new_state, db_updates, to_spend} = Core.finalize_exits(state, exits)
    Enum.each(to_spend, &State.exit_utxos/1)
    :ok = DB.multi_update(db_updates)
    {:reply, :ok, new_state}
  end

  def handle_call({:challenge_exits, _exits}, _from, state) do
    # TODO: implement
    # {new_state, db_updates} = Core.challenge_exits(state, exits)
    {new_state, db_updates} = {state, []}
    :ok = DB.multi_update(db_updates)
    {:reply, :ok, new_state}
  end

  def handle_call(:check_validity, _from, state) do
    {event_triggers, chain_status} = determine_invalid_exits(state)

    EventerAPI.emit_events(event_triggers)

    {:reply, chain_status, state}
  end

  # combine data from `ExitProcessor` and `API.State` to figure out what to do about exits
  defp determine_invalid_exits(state) do
    {:ok, eth_height_now} = Eth.get_ethereum_height()

    state
    |> Core.get_exiting_utxo_positions()
    |> Enum.map(&State.utxo_exists?/1)
    |> Core.invalid_exits(state, eth_height_now)
  end
end