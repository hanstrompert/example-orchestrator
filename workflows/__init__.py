from orchestrator.workflows import LazyWorkflowInstance

LazyWorkflowInstance("workflows.user_group.create_user_group", "create_user_group")
LazyWorkflowInstance("workflows.user_group.modify_user_group", "modify_user_group")
LazyWorkflowInstance("workflows.user_group.terminate_user_group", "terminate_user_group")
