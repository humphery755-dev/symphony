defmodule SymphonyElixir.Gitlab.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Gitlab.Adapter
  alias SymphonyElixir.Tracker

  describe "adapter dispatch" do
    test "tracker dispatches to Gitlab adapter when kind is gitlab" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "gitlab")
      assert Tracker.adapter() == Adapter
    end
  end

  describe "behaviour conformance" do
    test "@behaviour declaration is present" do
      behaviours =
        Adapter.module_info(:attributes)
        |> Keyword.get(:behaviour, [])

      assert SymphonyElixir.Tracker in behaviours
    end
  end
end
