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
def create_user_group():
    pass
