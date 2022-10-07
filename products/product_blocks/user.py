from orchestrator.domain.base import ProductBlockModel
from orchestrator.types import SubscriptionLifecycle

from products.product_blocks.user_group import UserGroupBlockInactive, UserGroupBlock


class UserBlockInactive(ProductBlockModel, product_block_name="User"):
    group: UserGroupBlockInactive
    name: str | None = None
    age: int | None = None


class UserBlock(UserBlockInactive, lifecycle=[SubscriptionLifecycle.ACTIVE, SubscriptionLifecycle.PROVISIONING]):
    group: UserGroupBlock
    name: str
    age: int | None = None
