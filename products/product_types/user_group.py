from orchestrator.domain.base import SubscriptionModel
from orchestrator.types import SubscriptionLifecycle

from products.product_blocks.user_group import UserGroupBlock, UserGroupBlockInactive


class UserGroupInactive(SubscriptionModel, is_base=True):
    settings: UserGroupBlockInactive


class UserGroupProvisioning(UserGroupInactive, lifecycle=[SubscriptionLifecycle.PROVISIONING]):
    settings: UserGroupBlock


class UserGroup(UserGroupProvisioning, lifecycle=[SubscriptionLifecycle.ACTIVE]):
    settings: UserGroupBlock
