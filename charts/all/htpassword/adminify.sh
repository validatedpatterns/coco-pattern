# yes this is procedural for demo systems onlys

HTPASSWD_FILE=${HOME}/ocp.htpasswd

while IFS=':' read -r username _; do
    # Use the 'username' variable here for further processing
    oc adm policy add-cluster-role-to-user cluster-admin $username
done < "$HTPASSWD_FILE"
