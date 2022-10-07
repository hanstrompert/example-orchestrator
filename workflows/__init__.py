from orchestrator.workflows import LazyWorkflowInstance, ALL_WORKFLOWS

LazyWorkflowInstance("workflows.user_group.create_user_group", "create_user_group")

print(f"DEBUG {ALL_WORKFLOWS}")
