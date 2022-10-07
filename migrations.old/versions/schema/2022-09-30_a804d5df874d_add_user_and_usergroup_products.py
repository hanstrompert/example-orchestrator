"""add User and UserGroup products.

Revision ID: a804d5df874d
Revises: 9bb25a23206b
Create Date: 2022-09-30 11:18:19.243692

"""
from uuid import uuid4

from alembic import op
from orchestrator.targets import Target

from migrations.helpers import create, delete

# revision identifiers, used by Alembic.
revision = "a804d5df874d"
down_revision = "9bb25a23206b"
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
            "tag": "USER",
            "status": "active",
            "product_blocks": ["UserBlock"],
            "fixed_inputs": {"Affiliation": "internal"},
        },
        "User external": {
            "product_id": uuid4(),
            "product_type": "User",
            "description": "User product",
            "tag": "USER",
            "status": "active",
            "product_blocks": ["UserBlock"],
            "fixed_inputs": {"Affiliation": "external"},
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
                "name": "Unique name of user",
                "age": "Age of user",
            },
            "depends_on_block_relations": ["UserGroupBlock"],
        },
    },
    "workflows": {  # Don't use this if multiple products share the same workflow
        "create_user_group": {
            "workflow_id": uuid4(),
            "target": Target.CREATE,
            "description": "Create user group",
            "tag": "UGC",
            "search_phrase": "User group",
        },
        "terminate_user_group": {
            "workflow_id": uuid4(),
            "target": Target.TERMINATE,
            "description": "Termiate user group",
            "tag": "UGT",
            "search_phrase": "User group",
        },
        "create_user": {
            "workflow_id": uuid4(),
            "target": Target.CREATE,
            "description": "Create user",
            "tag": "UC",
            "search_phrase": "User",
        },
        "terminate_user": {
            "workflow_id": uuid4(),
            "target": Target.TERMINATE,
            "description": "Termiate user",
            "tag": "UT",
            "search_phrase": "User",
        },
    },
}


old_products = {
    "products": {
        "Username registration": {
            "product_id": uuid4(),
            "product_type": "UNPT",
            "description": "The Username product",
            "tag": "UNR",
            "status": "active",
            "product_blocks": ["Username"],
            "fixed_inputs": {},
        },
    },
    "product_blocks": {
        "Username": {
            "product_block_id": uuid4(),
            "description": "Username Registration",
            "tag": "UNR",
            "status": "active",
            "resources": {
                "username": "Unique name of person",
            },
            "depends_on_block_relations": [],
        },
    },
    "workflows": {  # Don't use this if multiple products share the same workflow
        "create_username_registration": {
            "workflow_id": uuid4(),
            "target": Target.CREATE,
            "description": "Create User",
            "tag": "UNR",
            "search_phrase": "Username registration",
        }
    },
}


def upgrade() -> None:
    conn = op.get_bind()
    delete(conn, old_products)
    create(conn, new_products)
    # ensure_default_workflows(conn)


def downgrade() -> None:
    conn = op.get_bind()
    delete(conn, new_products)
    create(conn, old_products)
