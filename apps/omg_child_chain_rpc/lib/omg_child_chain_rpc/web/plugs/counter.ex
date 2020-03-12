# Copyright 2019-2020 OmiseGO Pte Ltd
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

defmodule OMG.ChildChainRPC.Plugs.Counter do
  defmacro __using__(_opts) do
    quote do
      @before_compile OMG.ChildChainRPC.Plugs.Counter
    end
  end

  defmacro __before_compile__(_) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        try do
          conn
          |> Plug.Conn.register_before_send(fn conn ->
            
            case Map.get(conn.assigns, :response) do
              nil -> :ok #Datadog.increment("transaction.submit.error", 1)
              _ ->:ok# Datadog.increment("transaction.submit.error", 1)
            end

            conn
          end)
          |> super(opts)
        catch
          kind, reason ->
           # Datadog.increment("transaction.submit.error", 1)
            :erlang.raise(kind, reason, System.stacktrace())
        end
      end
    end
  end
end