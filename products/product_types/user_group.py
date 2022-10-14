from orchestrator.domain.base import SubscriptionModel
from orchestrator.types import SubscriptionLifecycle

from products.product_blocks.user_group import UserGroupBlock, UserGroupBlockInactive, UserGroupBlockProvisioning


class UserGroupInactive(SubscriptionModel, is_base=True, lifecycle=[SubscriptionLifecycle.INITIAL]):
    settings: UserGroupBlockInactive


class UserGroupProvisioning(UserGroupInactive, lifecycle=[SubscriptionLifecycle.PROVISIONING]):
    settings: UserGroupBlockProvisioning


class UserGroup(UserGroupProvisioning, lifecycle=[SubscriptionLifecycle.ACTIVE]):
    settings: UserGroupBlock
