# htpassword

Set up a basic set of users on the hub cluster.
This is not for production use.

1. Based on using the [template secrets file](../../../values-encrypted-control-planes.yaml.template) create a htpasswd file at `~/ocp.htpasswd`.
2. The htpasswd file can be cteated by following [these instructions for linux and/or macOS](https://docs.openshift.com/container-platform/4.14/authentication/identity_providers/configuring-htpasswd-identity-provider.html#identity-provider-creating-htpasswd-file-windows_configuring-htpasswd-identity-provider)
3. After users have logged in once - run `adminify.sh` to give ALL users cluster-admin.
