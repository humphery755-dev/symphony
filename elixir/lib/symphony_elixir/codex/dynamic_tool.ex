defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Config

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @gitlab_api_tool "gitlab_api"
  @gitlab_api_description """
  Call GitLab REST API v4 using Symphony's configured GitLab endpoint and credentials.
  Use this for all GitLab operations: reading/writing issues, notes (comments), merge requests,
  labels, pipelines, and any other GitLab API endpoint.
  """
  @gitlab_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method for the request.",
        "enum" => ["GET", "POST", "PUT", "DELETE"]
      },
      "path" => %{
        "type" => "string",
        "description" => "API path relative to /api/v4/ (e.g. projects/TRDC-CSR%2Fcloud%2Fvehicle_detection%2Fthirdparty%2Fstrong-sort-test/issues/1/notes)."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON body for POST/PUT requests.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @gitlab_api_tool ->
        execute_gitlab_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    specs = []

    specs =
      case tracker_kind() do
        "linear" -> specs ++ linear_graphql_spec()
        _ -> specs
      end

    specs =
      case tracker_kind() do
        "gitlab" -> specs ++ gitlab_api_spec()
        _ -> specs
      end

    # Fallback: if tracker kind is unknown, provide both for maximum compatibility
    if specs == [] do
      linear_graphql_spec() ++ gitlab_api_spec()
    else
      specs
    end
  end

  defp linear_graphql_spec do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp gitlab_api_spec do
    [
      %{
        "name" => @gitlab_api_tool,
        "description" => @gitlab_api_description,
        "inputSchema" => @gitlab_api_input_schema
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Linear GraphQL execution
  # ---------------------------------------------------------------------------

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  # ---------------------------------------------------------------------------
  # GitLab API execution
  # ---------------------------------------------------------------------------

  defp execute_gitlab_api(arguments, _opts) do
    with {:ok, method, path, body} <- normalize_gitlab_api_arguments(arguments),
         {:ok, tracker} <- fetch_tracker_config(),
         {:ok, url, headers} <- build_gitlab_request(tracker, path) do
      execute_gitlab_request(method, url, headers, body)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_gitlab_api_arguments(arguments) when is_map(arguments) do
    method =
      case Map.get(arguments, "method") || Map.get(arguments, :method) do
        m when m in ~w(GET POST PUT DELETE) -> String.upcase(m)
        m when is_binary(m) -> {:error, {:invalid_method, m}}
        _ -> {:error, :missing_method}
      end

    path =
      case Map.get(arguments, "path") || Map.get(arguments, :path) do
        p when is_binary(p) and byte_size(p) > 0 -> String.trim(p)
        _ -> {:error, :missing_path}
      end

    body =
      case Map.get(arguments, "body") || Map.get(arguments, :body) do
        nil -> nil
        b when is_map(b) -> b
        _ -> {:error, :invalid_body}
      end

    case {method, path, body} do
      {{:error, _} = err, _, _} -> err
      {_, {:error, _} = err, _} -> err
      {_, _, {:error, _} = err} -> err
      {m, p, b} -> {:ok, m, p, b}
    end
  end

  defp normalize_gitlab_api_arguments(_arguments), do: {:error, :invalid_arguments}

  defp fetch_tracker_config do
    case Config.settings() do
      {:ok, settings} ->
        tracker = settings.tracker

        cond do
          is_nil(tracker.api_key) or tracker.api_key == "" ->
            {:error, :missing_gitlab_api_token}

          true ->
            {:ok, tracker}
        end

      {:error, reason} ->
        {:error, {:config_error, reason}}
    end
  end

  defp build_gitlab_request(tracker, path) do
    endpoint =
      if is_nil(tracker.endpoint) or tracker.endpoint == "" or
           tracker.endpoint == "https://api.linear.app/graphql" do
        "https://gitlab.com"
      else
        tracker.endpoint
      end

    base = String.trim_trailing(endpoint, "/") <> "/api/v4"
    normalized_path = String.trim_leading(path, "/")
    url = "#{base}/#{normalized_path}"

    headers = [
      {"PRIVATE-TOKEN", tracker.api_key},
      {"Content-Type", "application/json"}
    ]

    {:ok, url, headers}
  end

  defp execute_gitlab_request(method, url, headers, body) do
    req_opts = [headers: headers, connect_options: [timeout: 30_000]]

    req_opts =
      if not is_nil(body) do
        Keyword.put(req_opts, :json, body)
      else
        req_opts
      end

    result =
      case method do
        "GET" -> Req.get(url, req_opts)
        "POST" -> Req.post(url, req_opts)
        "PUT" -> Req.put(url, req_opts)
        "DELETE" -> Req.delete(url, req_opts)
      end

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        gitlab_success_response(status, response_body)

      {:ok, %{status: status, body: response_body}} ->
        gitlab_error_response(status, response_body)

      {:error, reason} ->
        failure_response(tool_error_payload({:gitlab_api_request, reason}))
    end
  end

  defp gitlab_success_response(status, body) do
    payload = %{
      "status" => status,
      "body" => body
    }

    dynamic_tool_response(true, encode_payload(payload))
  end

  defp gitlab_error_response(status, body) do
    payload = %{
      "error" => %{
        "message" => "GitLab API request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }

    dynamic_tool_response(false, encode_payload(payload))
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tracker_kind do
    case Config.settings() do
      {:ok, settings} ->
        settings.tracker.kind || "linear"

      {:error, _} ->
        "linear"
    end
  end

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`. `gitlab_api` expects an object with `method`, `path`, and optional `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_method) do
    %{
      "error" => %{
        "message" => "`gitlab_api` requires a `method` field (GET, POST, PUT, or DELETE)."
      }
    }
  end

  defp tool_error_payload({:invalid_method, method}) do
    %{
      "error" => %{
        "message" => "`gitlab_api` method must be one of GET, POST, PUT, DELETE. Got: #{inspect(method)}."
      }
    }
  end

  defp tool_error_payload(:missing_path) do
    %{
      "error" => %{
        "message" => "`gitlab_api` requires a non-empty `path` string (relative to /api/v4/)."
      }
    }
  end

  defp tool_error_payload(:invalid_body) do
    %{
      "error" => %{
        "message" => "`gitlab_api.body` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_gitlab_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitLab auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITLAB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:config_error, reason}) do
    %{
      "error" => %{
        "message" => "Failed to read Symphony configuration.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:gitlab_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitLab API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:gitlab_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitLab API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
