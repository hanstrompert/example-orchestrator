from orchestrator.domain.base import SubscriptionModel
from orchestrator.types import SubscriptionLifecycle, strEnum

from products.product_blocks.user import UserBlockProvisioning, UserBlockInactive, UserBlock


class Affiliation(strEnum):
    internal = "internal"
    external = "external"


class UserInactive(SubscriptionModel, is_base=True):
    affiliation: Affiliation
    settings: UserBlockInactive


class UserProvisioning(UserInactive, lifecycle=[SubscriptionLifecycle.PROVISIONING]):
    affiliation: Affiliation
    settings: UserBlockProvisioning


class User(UserProvisioning, lifecycle=[SubscriptionLifecycle.ACTIVE]):
    affiliation: Affiliation
    settings: UserBlock
