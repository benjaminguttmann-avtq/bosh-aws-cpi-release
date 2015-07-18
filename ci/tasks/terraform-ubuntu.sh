#!/usr/bin/env bash

set -e -x

source bosh-cpi-release/ci/tasks/utils.sh

check_param aws_access_key_id
check_param aws_secret_access_key
check_param concourse_ip

semver=`cat terraform-state-version/number`

# generates a plan
/terraform/terraform plan -out=ubuntu-bats.tfplan \
  -var "access_key=${aws_access_key_id}" \
  -var "secret_key=${aws_secret_access_key}" \
  -var "build_id=bats-ubuntu-${semver}" \
  -var "concourse_ip=${concourse_ip}" \
  bosh-concourse-ci/pipelines/bosh-aws-cpi

state_file=ubuntu-bats-${semver}.tfstate
export_file=terraform-ubuntu-exports-${semver}.sh

# applies the plan, generates a state file
/terraform/terraform apply -state=$state_file ubuntu-bats.tfplan

# exports values into an exports file
echo -e "#!/usr/bin/env bash" >> $export_file
echo -e "export UBUNTU_DIRECTOR=$(/terraform/terraform output -state=${state_file} director_vip)" >> $export_file
echo -e "export UBUNTU_VIP=$(/terraform/terraform output -state=${state_file} bats_vip)" >> $export_file
echo -e "export UBUNTU_SUBNET_ID=$(/terraform/terraform output -state=${state_file} subnet_id)" >> $export_file
echo -e "export UBUNTU_SECURITY_GROUP_NAME=$(/terraform/terraform output -state=${state_file} security_group_name)" >> $export_file
echo -e "export UBUNTU_AVAILABILITY_ZONE=$(/terraform/terraform output -state=${state_file} availability_zone)" >> $export_file
