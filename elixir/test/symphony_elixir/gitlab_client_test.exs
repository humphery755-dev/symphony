defmodule SymphonyElixir.Gitlab.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Gitlab.Client
  alias SymphonyElixir.Linear.Issue

  @valid_issue %{
    "id" => 1001,
    "iid" => 42,
    "title" => "Test Issue",
    "description" => "Issue description",
    "state" => "opened",
    "web_url" => "https://gitlab.com/group/project/-/issues/42",
    "assignee" => %{"id" => 200},
    "labels" => ["Todo", "bug"],
    "_links" => %{"blocked_by" => []},
    "created_at" => "2025-01-15T10:30:00Z",
    "updated_at" => "2025-01-20T14:00:00Z"
  }

  describe "normalize_issue/1" do
    test "maps GitLab issue fields to Issue struct" do
      issue = Client.normalize_issue_for_test(@valid_issue)

      assert %Issue{} = issue
      assert issue.id == "42"
      assert issue.identifier == "42"
      assert issue.title == "Test Issue"
      assert issue.description == "Issue description"
      assert issue.url == "https://gitlab.com/group/project/-/issues/42"
      assert issue.assignee_id == "200"
      assert issue.labels == ["Todo", "bug"]
      assert issue.state == "Todo"
      assert issue.assigned_to_worker == true
      assert issue.branch_name == nil
      assert issue.blocked_by == []
    end

    test "handles missing optional fields" do
      issue = Client.normalize_issue_for_test(%{"id" => 1, "iid" => 1, "title" => "Minimal"})

      assert issue.id == "1"
      assert issue.identifier == "1"
      assert issue.title == "Minimal"
      assert issue.description == nil
      assert issue.url == nil
      assert issue.assignee_id == nil
      assert issue.labels == []
      assert issue.state == "Todo"
      assert issue.priority == nil
      assert issue.blocked_by == []
    end

    test "derives state from labels matching configured states" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done"]
      )

      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["In Progress", "backend"]
        })

      assert issue.state == "In Progress"
    end

    test "falls back to opened when no labels match configured states" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done"]
      )

      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["custom-label"]
        })

      assert issue.state == "opened"
    end

    test "handles nil assignee" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "assignee" => nil
        })

      assert issue.assignee_id == nil
    end

    test "parses ISO 8601 datetime strings" do
      issue = Client.normalize_issue_for_test(@valid_issue)
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end
  end

  describe "assignee routing" do
    test "all issues assigned to worker when no assignee filter" do
      issue = Client.normalize_issue_for_test(@valid_issue, nil)
      assert issue.assigned_to_worker == true
    end

    test "unassigned issue not assigned to worker when filter is set" do
      issue =
        Client.normalize_issue_for_test(
          %{"id" => 1, "iid" => 1, "title" => "X", "assignee" => nil},
          "200"
        )

      assert issue.assigned_to_worker == false
    end

    test "matching assignee is assigned to worker" do
      issue =
        Client.normalize_issue_for_test(
          %{"id" => 1, "iid" => 1, "title" => "X", "assignee" => %{"id" => 200}},
          "200"
        )

      assert issue.assigned_to_worker == true
    end

    test "non-matching assignee is not assigned to worker" do
      issue =
        Client.normalize_issue_for_test(
          %{"id" => 1, "iid" => 1, "title" => "X", "assignee" => %{"id" => 999}},
          "200"
        )

      assert issue.assigned_to_worker == false
    end
  end

  describe "priority parsing" do
    test "parses priority::high as 2" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["priority::high", "bug"]
        })

      assert issue.priority == 2
    end

    test "parses priority::critical as 1" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["priority::critical"]
        })

      assert issue.priority == 1
    end

    test "parses priority::medium as 3" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["priority::medium"]
        })

      assert issue.priority == 3
    end

    test "parses priority::low as 4" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["priority::low"]
        })

      assert issue.priority == 4
    end

    test "parses P0-P9 as integer" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["P0"]
        })

      assert issue.priority == 0
    end

    test "returns nil for labels without priority" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "labels" => ["bug", "frontend"]
        })

      assert issue.priority == nil
    end
  end

  describe "blocked_by extraction" do
    test "extracts blocked_by from _links" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "_links" => %{
            "blocked_by" => [
              %{"id" => 10, "iid" => "5"},
              %{"id" => 20, "iid" => "8"}
            ]
          }
        })

      assert length(issue.blocked_by) == 2
      assert issue.blocked_by |> Enum.at(0) |> Map.get(:id) == "10"
      assert issue.blocked_by |> Enum.at(0) |> Map.get(:identifier) == "5"
      assert issue.blocked_by |> Enum.at(1) |> Map.get(:id) == "20"
      assert issue.blocked_by |> Enum.at(1) |> Map.get(:identifier) == "8"
    end

    test "returns empty when no blocked_by links" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X",
          "_links" => %{"blocked_by" => []}
        })

      assert issue.blocked_by == []
    end

    test "returns empty when no _links key" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => 1,
          "iid" => 1,
          "title" => "X"
        })

      assert issue.blocked_by == []
    end
  end

  describe "next_page_from_headers_for_test/2" do
    test "returns next page when body length equals page size" do
      body = Enum.to_list(1..100)
      assert Client.next_page_from_headers_for_test(body, 1) == {:ok, 2}
    end

    test "returns done when body has fewer items than page size" do
      body = Enum.to_list(1..50)
      assert Client.next_page_from_headers_for_test(body, 1) == :done
    end

    test "returns done for empty body" do
      assert Client.next_page_from_headers_for_test([], 1) == :done
    end
  end

  describe "fetch_issues_by_states/1" do
    test "returns empty list for empty state names" do
      assert Client.fetch_issues_by_states([]) == {:ok, []}
    end
  end

  describe "fetch_issue_states_by_ids/1" do
    test "returns empty list for empty ids" do
      assert Client.fetch_issue_states_by_ids([]) == {:ok, []}
    end
  end
end
