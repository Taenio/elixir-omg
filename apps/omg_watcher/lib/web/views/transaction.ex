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

defmodule OMG.Watcher.Web.View.Transaction do
  @moduledoc """
  The transaction view for rendering json
  """

  use OMG.Watcher.Web, :view

  alias OMG.API.Crypto
  alias OMG.Watcher.Web.Serializer

  def render("transaction.json", %{transaction: transaction}) do
    Crypto.encode16(transaction, ["txid", "cur12", "newowner1", "newowner2", "sig1", "sig2", "spender1", "spender2"])
    |> Serializer.Response.serialize(:success)
  end
end
