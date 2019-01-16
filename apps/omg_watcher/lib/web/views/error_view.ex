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

defmodule OMG.Watcher.Web.View.ErrorView do
  use OMG.Watcher.Web, :view

  @doc """
  Supports internal server error thrown by Phoenix.
  """
  def render("500.json", %{reason: %{message: message}} = conn) do
    OMG.RPC.Web.Error.serialize("server:internal_server_error", message)
    |> add_stack_trace(conn)
  end

  @doc """
  Renders error when no render clause matches or no template is found.
  """
  def template_not_found(_template, %{reason: reason}) do
    throw(
      "Unmatched render clause for template #{inspect(Map.get(reason, :template, "<unable to find>"))} in #{
        inspect(Map.get(reason, :module, "<unable to find>"))
      }"
    )
  end

  defp add_stack_trace(response, conn) do
    case Mix.env() do
      env when env in [:dev, :test] ->
        stack = "#{inspect(Map.get(conn, :stack))}"
        Kernel.put_in(response[:data][:messages], %{stacktrace: stack})

      _otherwise ->
        response
    end
  end
end
