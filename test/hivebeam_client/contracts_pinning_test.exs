defmodule HivebeamClient.ContractsPinningTest do
  use ExUnit.Case, async: true

  @contract_files [
    "CONTRACT_VERSION",
    "openapi.json",
    "event.schema.json",
    "ws.client.schema.json",
    "ws.server.schema.json",
    "examples.http.json",
    "examples.ws.json"
  ]

  test "pinned contracts include expected v1 assets" do
    contracts_dir = Path.expand("../../contracts", __DIR__)

    Enum.each(@contract_files, fn file ->
      assert File.exists?(Path.join(contracts_dir, file)), "missing contracts/#{file}"
    end)
  end

  test "pinned contracts match gateway api/v1 when gateway repo is available" do
    gateway_repo = System.get_env("HIVEBEAM_GATEWAY_REPO")

    if is_binary(gateway_repo) and File.dir?(gateway_repo) do
      contracts_dir = Path.expand("../../contracts", __DIR__)
      gateway_contracts_dir = Path.join([gateway_repo, "api", "v1"])

      Enum.each(@contract_files, fn file ->
        sdk_path = Path.join(contracts_dir, file)
        gateway_path = Path.join(gateway_contracts_dir, file)

        assert File.exists?(gateway_path), "gateway contract missing #{gateway_path}"
        assert file_hash(sdk_path) == file_hash(gateway_path), "contract mismatch for #{file}"
      end)
    else
      assert true
    end
  end

  defp file_hash(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
