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

defmodule OMG.LoadTest.Utils.Sync do
  @moduledoc """
  Utility module for repeating a function call until a given criteria is met.
  """

  @doc """
  Repeats f until f returns {:ok, ...}, :ok OR exception is raised (see :erlang.exit, :erlang.error) OR timeout
  after `timeout` milliseconds specified

  Simple throws and :badmatch are treated as signals to repeat
  """
  def ok(f, timeout) do
    fn -> repeat_until_ok(f) end
    |> Task.async()
    |> Task.await(timeout)
  end

  defp repeat_until_ok(f) do
    Process.sleep(100)

    try do
      case f.() do
        :ok = return -> return
        {:ok, _} = return -> return
        _ -> repeat_until_ok(f)
      end
    catch
      _something -> repeat_until_ok(f)
      :error, {:badmatch, _} -> repeat_until_ok(f)
    end
  end
end
