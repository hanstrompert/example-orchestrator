"""add username registration product.

Revision ID: 9bb25a23206b
Revises: bed6bc0b197a
Create Date: 2022-06-28 10:38:15.116689

"""
from uuid import uuid4

from alembic import op
from orchestrator.targets import Target

from migrations.helpers import create, delete

# update revision and down_revision as needed
revision = "9bb25a23206b"
down_revision = "bed6bc0b197a"
branch_labels = None
depends_on = None

new_products = {
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
    create(conn, new_products)
    # ensure_default_workflows(conn)


def downgrade() -> None:
    conn = op.get_bind()
    delete(conn, new_products)
