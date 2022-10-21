"""add User and UserGroup products.

Revision ID: 46287618baec
Revises: bed6bc0b197a
Create Date: 2022-09-30 14:02:14.929319

"""
from uuid import uuid4

import sqlalchemy as sa
from alembic import op
from orchestrator.migrations.helpers import create_workflow, delete_workflow
from orchestrator.targets import Target

from migrations.helpers import create, delete

# revision identifiers, used by Alembic.
revision = "46287618baec"
down_revision = "bed6bc0b197a"
branch_labels = None
depends_on = None

new_products = {
    "products": {
        "User group": {
            "product_id": uuid4(),
            "product_type": "UserGroup",
            "description": "User group product",
            "tag": "GROUP",
            "status": "active",
            "product_blocks": ["UserGroupBlock"],
            "fixed_inputs": {},
        },
        "User internal": {
            "product_id": uuid4(),
            "product_type": "User",
            "description": "User product",
            "tag": "INT_USER",
            "status": "active",
            "product_blocks": ["UserBlock"],
            "fixed_inputs": {"affiliation": "internal"},
        },
        "User external": {
            "product_id": uuid4(),
            "product_type": "User",
            "description": "User product",
            "tag": "EXT_USER",
            "status": "active",
            "product_blocks": ["UserBlock"],
            "fixed_inputs": {"affiliation": "external"},
        },
    },
    "product_blocks": {
        "UserGroupBlock": {
            "product_block_id": uuid4(),
            "description": "User group settings",
            "tag": "UGS",
            "status": "active",
            "resources": {
                "group_name": "Unique name of user group",
                "group_id": "Group ID in group management system"
            },
            "depends_on_block_relations": [],
        },
        "UserBlock": {
            "product_block_id": uuid4(),
            "description": "User settings",
            "tag": "US",
            "status": "active",
            "resources": {
                "affiliation": "User affiliation",
                "username": "Unique name of user",
                "age": "Age of user",
                "user_id": "User ID in user management system"
            },
            "depends_on_block_relations": ["UserGroupBlock"],
        },
    },
    "workflows": {},
}

new_workflows = [
    {
        "name": "create_user_group",
        "target": Target.CREATE,
        "description": "Create user group",
        "product_type": "UserGroup",
    },
    {
        "name": "modify_user_group",
        "target": Target.MODIFY,
        "description": "Modify user group",
        "product_type": "UserGroup",
    },
    {
        "name": "terminate_user_group",
        "target": Target.TERMINATE,
        "description": "Terminate user group",
        "product_type": "UserGroup",
    },
    {
        "name": "create_user",
        "target": Target.CREATE,
        "description": "Create user",
        "product_type": "User",
    },
    {
        "name": "modify_user",
        "target": Target.MODIFY,
        "description": "Modify user",
        "product_type": "User",
    },
    {
        "name": "terminate_user",
        "target": Target.TERMINATE,
        "description": "Terminate user",
        "product_type": "User",
    },
]


def upgrade() -> None:
    conn = op.get_bind()
    create(conn, new_products)
    for workflow in new_workflows:
        create_workflow(conn, workflow)
    # ensure_default_workflows(conn)


def downgrade() -> None:
    conn = op.get_bind()
    for workflow in new_workflows:
        delete_workflow(conn, workflow["name"])
    delete(conn, new_products)
