defmodule SymphonyElixir.Gitlab.Client do
  @moduledoc """
  GitLab REST API v4 client for polling project issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter(tracker),
         {:ok, issues} <- fetch_opened_issues(tracker, assignee_filter) do
      {:ok, Enum.filter(issues, &candidate_issue?(&1, tracker))}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_config(tracker),
           {:ok, issues} <- fetch_opened_issues(tracker, nil) do
        state_set = MapSet.new(normalized, &String.downcase/1)

        {:ok,
         Enum.filter(issues, fn issue ->
           issue.labels == [] or Enum.any?(issue.labels, &MapSet.member?(state_set, String.downcase(&1)))
         end)}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    if ids == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_config(tracker),
           {:ok, assignee_filter} <- routing_assignee_filter(tracker) do
        fetch_issues_by_iids(ids, tracker, assignee_filter)
      end
    end
  end

  defp fetch_issues_by_iids(iids, tracker, assignee_filter) do
    with {:ok, headers} <- api_headers(tracker) do
      iid_params = Enum.map_join(iids, "&", &"iids[]=#{uri_encode(&1)}")
      url = "#{api_base(tracker)}/projects/#{uri_encode(tracker.project_slug)}/issues?#{iid_params}&per_page=100"

      case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, Enum.map(body, &normalize_issue(&1, assignee_filter))}

        {:ok, %{status: 404}} ->
          {:ok, []}

        {:ok, %{status: status}} ->
          {:error, {:gitlab_api_status, status}}

        {:error, reason} ->
          {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  @doc """
  POST /projects/:id/issues/:issue_iid/notes
  """
  @spec create_note(String.t(), String.t()) :: :ok | {:error, term()}
  def create_note(issue_identifier, body) when is_binary(issue_identifier) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, headers} <- api_headers(tracker) do
      url =
        "#{api_base(tracker)}/projects/#{uri_encode(tracker.project_slug)}/issues/#{uri_encode(issue_identifier)}/notes"

      case Req.post(url, headers: headers, json: %{body: body}, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 201}} ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:gitlab_api_status, status}}

        {:error, reason} ->
          {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  @doc """
  PUT /projects/:id/issues/:issue_iid — merge state label, preserve existing labels.
  When transitioning to a terminal state, also close the issue.
  """
  @spec update_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue(issue_identifier, state_name) when is_binary(issue_identifier) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, current} <- do_get_issue_raw(issue_identifier, tracker) do
      merged_labels = merge_state_label(current, tracker, state_name)
      put_issue_update(issue_identifier, merged_labels, state_name, tracker)
    end
  end

  defp put_issue_update(issue_identifier, merged_labels, state_name, tracker) do
    terminal_set = MapSet.new(tracker.terminal_states, &String.downcase/1)
    is_terminal = MapSet.member?(terminal_set, String.downcase(state_name))
    body = build_state_body(merged_labels, is_terminal)

    with {:ok, headers} <- api_headers(tracker) do
      url =
        "#{api_base(tracker)}/projects/#{uri_encode(tracker.project_slug)}/issues/#{uri_encode(issue_identifier)}"

      case Req.put(url, headers: headers, json: body, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status}} -> {:error, {:gitlab_api_status, status}}
        {:error, reason} -> {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  @doc """
  Fetch a single issue by IID.
  """
  @spec get_issue(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def get_issue(issue_identifier) when is_binary(issue_identifier) do
    tracker = Config.settings!().tracker

    with {:ok, raw} <- do_get_issue_raw(issue_identifier, tracker) do
      {:ok, normalize_issue(raw, nil)}
    end
  end

  # ── test helpers ──

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue, nil)

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter = build_assignee_filter_from_value(assignee)
    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_from_headers_for_test(list(), pos_integer()) :: {:ok, pos_integer()} | :done
  def next_page_from_headers_for_test(body, page) when is_list(body) and is_integer(page) do
    next_page_from_headers(body, page)
  end

  # ── assignee routing ──

  defp routing_assignee_filter(tracker) do
    case tracker.assignee do
      nil ->
        {:ok, nil}

      assignee when is_binary(assignee) ->
        case normalize_assignee_value(assignee) do
          nil -> {:ok, nil}
          "me" -> resolve_viewer_assignee(tracker)
          normalized -> {:ok, %{match_values: MapSet.new([normalized])}}
        end
    end
  end

  defp build_assignee_filter_from_value(nil), do: nil

  defp build_assignee_filter_from_value(value) when is_binary(value) do
    case normalize_assignee_value(value) do
      nil -> nil
      normalized -> %{match_values: MapSet.new([normalized])}
    end
  end

  defp resolve_viewer_assignee(tracker) do
    with {:ok, headers} <- api_headers(tracker) do
      case Req.get("#{api_base(tracker)}/user", headers: headers, connect_options: [timeout: 10_000]) do
        {:ok, %{status: 200, body: %{"id" => user_id}}} ->
          {:ok, %{match_values: MapSet.new([to_string(user_id)])}}

        {:ok, _} ->
          {:error, :missing_gitlab_user_identity}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp assigned_to_worker?(_issue_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values}) do
    assignee_id = extract_assignee_id(assignee)

    case assignee_id do
      nil -> false
      id -> MapSet.member?(match_values, id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  # ── label merging for state updates ──

  defp merge_state_label(issue, tracker, new_state) do
    all_state_names =
      (tracker.active_states ++ tracker.terminal_states)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    current_labels = issue["labels"] || []

    # Remove any existing state labels, add the new one
    filtered =
      Enum.reject(current_labels, fn label ->
        MapSet.member?(all_state_names, String.downcase(label))
      end)

    (filtered ++ [new_state]) |> Enum.uniq()
  end

  defp build_state_body(labels, true = _is_terminal) do
    %{labels: Enum.join(labels, ","), state_event: "close"}
  end

  defp build_state_body(labels, false = _is_terminal) do
    %{labels: Enum.join(labels, ",")}
  end

  # ── private helpers ──

  defp validate_tracker_config(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_gitlab_token}
      is_nil(tracker.project_slug) -> {:error, :missing_gitlab_project_id}
      true -> :ok
    end
  end

  defp do_get_issue_raw(issue_identifier, tracker) do
    with {:ok, headers} <- api_headers(tracker) do
      url =
        "#{api_base(tracker)}/projects/#{uri_encode(tracker.project_slug)}/issues/#{uri_encode(issue_identifier)}"

      case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :issue_not_found}
        {:ok, %{status: status}} -> {:error, {:gitlab_api_status, status}}
        {:error, reason} -> {:error, {:gitlab_api_request, reason}}
      end
    end
  end

  defp fetch_opened_issues(tracker, assignee_filter) do
    do_fetch_pages(tracker, [], 1, assignee_filter)
  end

  defp do_fetch_pages(tracker, acc_issues, page, assignee_filter) do
    with {:ok, headers} <- api_headers(tracker) do
      url =
        "#{api_base(tracker)}/projects/#{uri_encode(tracker.project_slug)}/issues" <>
          "?state=opened&per_page=#{@issue_page_size}&page=#{page}"

      Req.get(url, headers: headers, connect_options: [timeout: 30_000])
      |> handle_page_response(tracker, acc_issues, page, assignee_filter)
    end
  end

  defp handle_page_response({:ok, %{status: 200, body: body}}, tracker, acc_issues, page, assignee_filter)
       when is_list(body) do
    issues = Enum.map(body, &normalize_issue(&1, assignee_filter))
    updated_acc = acc_issues ++ issues
    process_next_page(tracker, updated_acc, page, body, assignee_filter)
  end

  defp handle_page_response({:ok, %{status: 200, body: body}}, _tracker, acc_issues, _page, assignee_filter) do
    {:ok, acc_issues ++ [normalize_issue(body, assignee_filter)]}
  end

  defp handle_page_response({:ok, %{status: status}}, _tracker, _acc_issues, _page, _assignee_filter) do
    {:error, {:gitlab_api_status, status}}
  end

  defp handle_page_response({:error, reason}, _tracker, _acc_issues, _page, _assignee_filter) do
    {:error, {:gitlab_api_request, reason}}
  end

  defp process_next_page(tracker, acc_issues, page, body, assignee_filter) do
    case next_page_from_headers(body, page) do
      {:ok, next_page} -> do_fetch_pages(tracker, acc_issues, next_page, assignee_filter)
      :done -> {:ok, acc_issues}
    end
  end

  defp next_page_from_headers(body, current_page) when is_list(body) do
    if length(body) == @issue_page_size do
      {:ok, current_page + 1}
    else
      :done
    end
  end

  defp next_page_from_headers(_body, _current_page), do: :done

  defp candidate_issue?(%Issue{labels: labels}, tracker) do
    active_set = active_state_set(tracker)
    terminal_set = terminal_state_set(tracker)

    in_active? = Enum.any?(labels, &MapSet.member?(active_set, String.downcase(&1)))
    in_terminal? = Enum.any?(labels, &MapSet.member?(terminal_set, String.downcase(&1)))

    # Candidate: in active state, or completely unlabeled (new issue)
    # Exclude: in terminal state, or has labels but none are active
    not in_terminal? and (in_active? or labels == [])
  end

  defp active_state_set(tracker), do: MapSet.new(tracker.active_states, &String.downcase/1)
  defp terminal_state_set(tracker), do: MapSet.new(tracker.terminal_states, &String.downcase/1)

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    labels = extract_labels(issue)
    assignee = issue["assignee"]
    iid = issue["iid"] |> to_string()

    %Issue{
      id: iid,
      identifier: iid,
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(labels),
      state: derive_state(labels),
      branch_name: nil,
      url: issue["web_url"],
      assignee_id: extract_assignee_id(assignee),
      blocked_by: extract_blocked_by(issue),
      labels: labels,
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp extract_labels(_), do: []

  defp derive_state(labels) do
    tracker = Config.settings!().tracker
    all_states = tracker.active_states ++ tracker.terminal_states
    state_set = MapSet.new(all_states, &String.downcase/1)

    case Enum.find(labels, &MapSet.member?(state_set, String.downcase(&1))) do
      nil when labels == [] -> List.first(tracker.active_states) || "opened"
      nil -> "opened"
      state -> state
    end
  end

  defp extract_assignee_id(nil), do: nil
  defp extract_assignee_id(%{"id" => id}), do: to_string(id)
  defp extract_assignee_id(_), do: nil

  defp extract_blocked_by(%{"_links" => %{"blocked_by" => blocked_list}}) when is_list(blocked_list) do
    blocked_list
    |> Enum.map(fn item ->
      %{
        id: item["id"] |> to_string(),
        identifier: item["iid"] |> to_string(),
        state: nil
      }
    end)
  end

  defp extract_blocked_by(_), do: []

  @priority_map %{
    "priority::critical" => 1,
    "critical" => 1,
    "priority::high" => 2,
    "high" => 2,
    "priority::medium" => 3,
    "medium" => 3,
    "priority::low" => 4,
    "low" => 4
  }

  defp parse_priority(labels) when is_list(labels) do
    Enum.find_value(labels, &priority_from_label/1)
  end

  defp parse_priority(_labels), do: nil

  defp priority_from_label(label) do
    normalized = String.downcase(String.trim(label))

    cond do
      Map.has_key?(@priority_map, normalized) ->
        Map.get(@priority_map, normalized)

      match?(<<?p, n>> when n >= ?0 and n <= ?9, normalized) ->
        normalized |> String.at(1) |> String.to_integer()

      true ->
        nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_assignee_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp api_base(tracker) do
    endpoint =
      if is_nil(tracker.endpoint) or tracker.endpoint == "https://api.linear.app/graphql" do
        "https://gitlab.com"
      else
        tracker.endpoint
      end

    String.trim_trailing(endpoint, "/") <> "/api/v4"
  end

  defp api_headers(tracker) do
    case tracker.api_key do
      nil ->
        {:error, :missing_gitlab_token}

      token ->
        {:ok,
         [
           {"PRIVATE-TOKEN", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp uri_encode(value) when is_binary(value), do: URI.encode_www_form(value)
  defp uri_encode(value), do: URI.encode_www_form(to_string(value))
end
