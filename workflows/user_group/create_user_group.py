from uuid import uuid4

from orchestrator.forms import FormPage
from orchestrator.targets import Target
from orchestrator.types import FormGenerator, State, SubscriptionLifecycle, UUIDstr
from orchestrator.workflow import done, init, step, workflow
from orchestrator.workflows.steps import resync, set_status, store_process_subscription
from orchestrator.workflows.utils import wrap_create_initial_input_form

from products.product_types.user_group import UserGroupInactive, UserGroupProvisioning


def initial_input_form_generator(product_name: str) -> FormGenerator:
    class CreateUserGroupForm(FormPage):
        class Config:
            title = product_name

        group_name: str

    user_input = yield CreateUserGroupForm

    return user_input.dict()


def _provision_in_group_management_system(user_group: str) -> int:

    return abs(hash(user_group))


@step("Create subscription")
def create_subscription(
    product: UUIDstr,
    group_name: str,
) -> State:
    user_group = UserGroupInactive.from_product_id(product, uuid4())  # TODO mock organizations endpoint
    user_group.settings.group_name = group_name
    user_group = UserGroupProvisioning.from_other_lifecycle(user_group, SubscriptionLifecycle.PROVISIONING)
    user_group.description = f"User group {group_name}"

    return {
        "subscription": user_group,
        "subscription_id": user_group.subscription_id,
        "subscription_description": user_group.description,
    }


@step("Provision user group")
def provision_user_group(subscription: UserGroupProvisioning, group_name: str) -> State:
    group_id = _provision_in_group_management_system(group_name)
    subscription.settings.group_id = group_id

    return {"subscription": subscription, "group_id": group_id}


@workflow(
    "Create user group",
    initial_input_form=wrap_create_initial_input_form(initial_input_form_generator),
    target=Target.CREATE,
)
def create_user_group():
    step_list = (
        init
        >> create_subscription
        >> store_process_subscription(Target.CREATE)
        >> provision_user_group
        >> set_status(SubscriptionLifecycle.ACTIVE)
        >> resync
        >> done
    )

    return step_list
