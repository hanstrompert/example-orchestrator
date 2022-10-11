from orchestrator.workflows import ALL_WORKFLOWS, LazyWorkflowInstance

LazyWorkflowInstance("workflows.user_group.create_user_group", "create_user_group")

print(f"DEBUG {ALL_WORKFLOWS}")
