from orchestrator.forms import FormPage
from orchestrator.forms.validators import DisplaySubscription
from orchestrator.targets import Target
from orchestrator.types import InputForm, State, SubscriptionLifecycle, UUIDstr
from orchestrator.workflow import done, init, step, workflow
from orchestrator.workflows.steps import resync, set_status, store_process_subscription, unsync
from orchestrator.workflows.utils import wrap_modify_initial_input_form

from products import UserGroup


def initial_input_form_generator(subscription_id: UUIDstr, organisation: UUIDstr) -> InputForm:
    temp_subscription_id = subscription_id

    class TerminateForm(FormPage):
        subscription_id: DisplaySubscription = temp_subscription_id  # type: ignore

        # _check_not_in_use_by_nsi_lp: classmethod = root_validator(allow_reuse=True)(validate_not_in_use_by_nsi_lp)

    return TerminateForm


def _deprovision_in_group_management_system(user_id: int) -> int:
    pass


@step("Deprovision user group")
def deprovision_user_group(subscription: UserGroup) -> State:
    _deprovision_in_group_management_system(subscription.settings.group_id)
    return {"user_group_deprovision_status": f"deprovisioned user group with id {subscription.settings.group_id}"}


@workflow(
    "Terminate user group",
    initial_input_form=wrap_modify_initial_input_form(initial_input_form_generator),
    target=Target.TERMINATE,
)
def terminate_user_group():
    step_list = (
        init
        >> store_process_subscription(Target.TERMINATE)
        >> unsync
        >> deprovision_user_group
        >> set_status(SubscriptionLifecycle.TERMINATED)
        >> resync
        >> done
    )
    return step_list
