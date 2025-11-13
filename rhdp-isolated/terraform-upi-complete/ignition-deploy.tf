# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Deploy ignition configs to bastion HTTP server
# Since Terraform runs on the bastion, we use local file operations (no SSH)

# Copy ignition configs to bastion HTTP server directory
resource "null_resource" "deploy_ignition_to_bastion" {
  # Trigger when ignition config paths change
  triggers = {
    bootstrap_ign = filemd5(var.local_ignition_dir != "" ? "${var.local_ignition_dir}/bootstrap.ign" : "/dev/null")
    master_ign    = filemd5(var.local_ignition_dir != "" ? "${var.local_ignition_dir}/master.ign" : "/dev/null")
    worker_ign    = filemd5(var.local_ignition_dir != "" ? "${var.local_ignition_dir}/worker.ign" : "/dev/null")
  }

  # Copy ignition files locally (we're running on the bastion)
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      if [ -z "${var.local_ignition_dir}" ]; then
        echo "ERROR: local_ignition_dir not set"
        exit 1
      fi
      
      echo "Deploying ignition configs to bastion HTTP server..."
      
      # Ensure ignition directory exists
      sudo mkdir -p /var/cache/oc-mirror/ignition
      sudo chown azureuser:azureuser /var/cache/oc-mirror/ignition
      
      # Copy ignition files (local copy, no SSH needed)
      cp ${var.local_ignition_dir}/bootstrap.ign /var/cache/oc-mirror/ignition/
      cp ${var.local_ignition_dir}/master.ign /var/cache/oc-mirror/ignition/
      cp ${var.local_ignition_dir}/worker.ign /var/cache/oc-mirror/ignition/
      
      # Set permissions
      chmod 644 /var/cache/oc-mirror/ignition/*.ign
      
      # Ensure ignition HTTP server is running
      if ! systemctl is-active --quiet ignition-http.service; then
        echo "Starting ignition HTTP server..."
        sudo systemctl start ignition-http.service
      fi
      
      # Verify accessibility via HTTP
      if ! curl -sf http://localhost:8081/bootstrap.ign > /dev/null; then
        echo "ERROR: Cannot access ignition server on localhost:8081"
        systemctl status ignition-http.service
        exit 1
      fi
      
      echo "✅ Ignition configs deployed and verified accessible at http://localhost:8081/"
    EOT
  }
}
