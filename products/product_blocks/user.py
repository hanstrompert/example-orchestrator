from orchestrator.domain.base import ProductBlockModel
from orchestrator.types import SubscriptionLifecycle

from products.product_blocks.user_group import UserGroupBlock, UserGroupBlockInactive


class UserBlockInactive(ProductBlockModel, lifecycle=[SubscriptionLifecycle.INITIAL], product_block_name="UserBlock"):
    group: UserGroupBlockInactive
    username: str | None = None
    age: int | None = None
    user_id: int | None = None


class UserBlock(UserBlockInactive, lifecycle=[SubscriptionLifecycle.PROVISIONING, SubscriptionLifecycle.ACTIVE]):
    group: UserGroupBlock
    username: str
    age: int | None = None
    user_id: int
