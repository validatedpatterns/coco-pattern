algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]
url = "https://kbs.{{ hub_domain }}"

[token_configs.kbs]
url = "https://kbs.{{ hub_domain }}"
cert = """{{ trustee_cert }}"""
'''

"cdh.toml"  = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "https://kbs.{{ hub_domain }}"
kbs_cert = """{{ trustee_cert }}"""


[image]
image_security_policy_uri = 'kbs:///default/security-policy/{{ security_policy_flavour }}'
# On baremetal (kata), CDH fetches this credential from KBS to authenticate
# with container registries inside the CVM. On Azure peer-pods (kata-remote),
# CDH does NOT use this URI — registry auth is handled via imagePullSecrets
# on the workload's service account instead. Kept here for baremetal support.
authenticated_registry_credentials_uri = 'kbs:///default/credential/regcred'
{% if registry_ca_certs | default([]) | length > 0 %}
extra_root_certificates = [{% for cert in registry_ca_certs %}"""
{{ cert }}"""{%- if not loop.last %}, {% endif %}{% endfor %}]
{% endif %}
'''

"policy.rego" = '''
package agent_policy

import future.keywords.in
import future.keywords.if
import future.keywords.every

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := false
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default ExecProcessRequest := false
default SetPolicyRequest := true 
default WriteStreamRequest := false

ExecProcessRequest if {
    input_command = concat(" ", input.process.Args)
    some allowed_command in policy_data.allowed_commands
    input_command == allowed_command
}

policy_data := {
  "allowed_commands": [
        "curl http://127.0.0.1:8006/cdh/resource/default/attestation-status/status",
        "curl http://127.0.0.1:8006/cdh/resource/default/attestation-status/random"
  ]
}
'''
