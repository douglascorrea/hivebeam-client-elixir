defmodule HivebeamClient.Error do
  @moduledoc false

  defexception [:type, :message, :status, :details]

  @type error_type ::
          :invalid_config
          | :transport_error
          | :decode_error
          | :unauthorized
          | :not_found
          | :invalid_request
          | :server_error
          | :http_error
          | :session_not_attached

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          status: integer() | nil,
          details: term()
        }

  @spec new(error_type(), String.t(), term()) :: t()
  def new(type, message, details \\ nil)
      when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: details}
  end

  @spec from_http(non_neg_integer(), term()) :: t()
  def from_http(status, body) when is_integer(status) do
    message = error_message(body)

    type =
      cond do
        status == 401 -> :unauthorized
        status == 404 -> :not_found
        status == 422 -> :invalid_request
        status >= 500 -> :server_error
        true -> :http_error
      end

    %__MODULE__{type: type, status: status, message: message, details: body}
  end

  @spec from_transport(term()) :: t()
  def from_transport(reason) do
    %__MODULE__{
      type: :transport_error,
      message: "transport request failed",
      details: reason
    }
  end

  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(%{error: message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: String.trim(message)
  defp error_message(_), do: "request failed"
end
