from orchestrator.domain.base import ProductBlockModel
from orchestrator.types import SubscriptionLifecycle


class UserGroupBlockInactive(ProductBlockModel, product_block_name="User group"):
    name: str | None = None


class UserGroupBlock(
    UserGroupBlockInactive, lifecycle=[SubscriptionLifecycle.ACTIVE, SubscriptionLifecycle.PROVISIONING]
):
    name: str
