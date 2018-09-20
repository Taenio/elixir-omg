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

defmodule OMG.API.State.PropTest.DifferentSpenderTransaction do
  @moduledoc """
  Generates function needed to make transaction with wrong spender in propcheck test
  """
  use PropCheck
  alias OMG.API.PropTest.Generators
  alias OMG.API.PropTest.Helper
  alias OMG.API.State.PropTest

  def impl(tr, fee_map),
    do:
      OMG.API.State.PropTest.StateCoreGS.exec(
        PropTest.Transaction.create(tr),
        PropTest.Transaction.create_fee_map(fee_map)
      )

  def args(%{model: %{history: history}}) do
    {unspent, _spent} = Helper.get_utxos(history)
    available_currencies = Map.values(unspent) |> Enum.map(& &1.currency) |> Enum.uniq()

    let [currency <- oneof(available_currencies)] do
      unspent = unspent |> Map.to_list() |> Enum.filter(fn {_, %{currency: val}} -> val == currency end)

      let [
        owners <- Generators.new_owners(),
        inputs <- Generators.input_transaction(unspent),
        diff_owner <- oneof(OMG.API.TestHelper.entities_stable() |> Map.keys())
      ] do
        let [which <- choose(0, length(inputs) - 1)] do
          {{position, info}, _} = List.pop_at(inputs, which)
          inputs = List.replace_at(inputs, which, {position, Map.put(info, :owner, diff_owner)})

          [
            PropTest.Transaction.prepare_args(inputs, owners),
            %{currency => 0}
          ]
        end
      end
    end
  end

  def pre(%{model: %{history: history}}, [{inputs, _, _}, _]) do
    {unspent, _spend} = Helper.get_utxos(history)

    inputs
    |> Enum.any?(fn {position, owner} ->
      Map.has_key?(unspent, position) && Map.get(unspent, position)[:owner] != owner
    end)
  end

  def post(_, _, {:error, :incorrect_spender}), do: true

  def next(%{model: %{history: history, balance: balance} = model} = state, [transaction | _], _) do
    %{
      state
      | model: %{model | history: [{:different_spender_transaction, transaction} | history], balance: balance}
    }
  end

  defmacro __using__(_opt) do
    quote location: :keep do
      defcommand(:different_spender_transaction, do: unquote(Helper.create_delegate_to_defcommand(__MODULE__)))
    end
  end
end
