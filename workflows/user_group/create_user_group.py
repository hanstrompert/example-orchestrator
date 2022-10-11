# @create_workflow("Create SN8 Light Path", initial_input_form=initial_input_form_generator)
# def create_sn8_light_path() -> StepList:
#     """Create an SN8 Light Path.
#
#     This workflow creates a Light Path on the SURFnet8 network.
#
#     All data administered is captured in :class:`surf.products.product_types.sn8_lp.Sn8LightPath`
#     """
#     return (
#         begin
#         >> construct_lightpath_model
#         >> store_process_subscription(Target.CREATE)
#         >> create_ims_circuit
#         >> create_nso_service_model
#         >> re_deploy_nso
#         >> take_ims_circuit_in_service(is_redundant=False)
#         >> send_confirmation_email()
#     )
import logging
from typing import Any
from uuid import uuid4

from orchestrator.domain.base import SubscriptionModel
from orchestrator.forms import FormPage
from orchestrator.forms.validators import Divider, Label, ListOfOne, OrganisationId
from orchestrator.targets import Target
from orchestrator.types import FormGenerator, State, SubscriptionLifecycle, UUIDstr
from orchestrator.workflow import StepList, Workflow, begin, conditional, done, init, make_workflow, step, workflow
from orchestrator.workflows.steps import resync, set_status, store_process_subscription, unsync
from orchestrator.workflows.utils import wrap_create_initial_input_form
from orchestrator.utils.redis import caching_models_enabled


from products.product_types.user_group import UserGroup, UserGroupInactive, UserGroupProvisioning


# from surf.forms.validators import JiraTicketId, bandwidth
# from surf.products.product_types.sn8_nsistp import NsistpInactive, NsistpProvisioning
# from surf.products.services.subscription import subscription_description
# from surf.workflows.nsistp.sn8.shared.forms import (
#     is_alias_in_out_validator,
#     is_alias_in_validator,
#     is_alias_out_validator,
#     nsistp_service_port,
#     stp_description_validator,
#     stp_id_validator,
#     topology_validator,
# )
# from surf.workflows.workflow import create_workflow


def initial_input_form_generator(product_name: str) -> FormGenerator:
    class CreateUserGroupForm(FormPage):
        class Config:
            title = product_name

        group_name: str

    user_input = yield CreateUserGroupForm

    return user_input.dict()


@step("Create subscription")
def create_subscription(
    product: UUIDstr,
    group_name: str,
) -> State:
    user_group = UserGroupInactive.from_product_id(product, uuid4())
    user_group.settings.group_name = group_name
    # user_group = UserGroupProvisioning.from_other_lifecycle(user_group, SubscriptionLifecycle.PROVISIONING)
    # user_group.description = f"User group {group_name}"

    return {
        "subscription": user_group,
        "subscription_id": user_group.subscription_id,
        "subscription_description": user_group.description,
    }


@step("Set description")
def set_description(subscription: UserGroupInactive, group_name: str) -> State:
    subscription.description = f"User group {group_name}"
    return {
        "subsscription": subscription
    }


@step("Set in sync and update lifecyle to provisioning")
def try_it_out(subscription: UserGroupInactive) -> State:
    subscription.insync = True

    new_sub = UserGroup.from_other_lifecycle(subscription, SubscriptionLifecycle.ACTIVE)
    return {
        "subscription": new_sub
    }


@workflow(
    "Create user group",
    initial_input_form=wrap_create_initial_input_form(initial_input_form_generator),
    target=Target.CREATE,
)
def create_user_group():
    logger = logging.getLogger("create_user_group")
    logger.debug("made it here!")

    step_list = (
        init
        >> create_subscription
        >> store_process_subscription(Target.CREATE)
        >> set_description
        >> try_it_out
        # >> set_status(SubscriptionLifecycle.ACTIVE)
        # >> resync
        >> done
    )
    return step_list
