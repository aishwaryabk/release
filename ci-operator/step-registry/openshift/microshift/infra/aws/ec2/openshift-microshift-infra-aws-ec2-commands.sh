#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${EC2_REGION:-$LEASED_RESOURCE}"
JOB_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

if [[ "${EC2_AMI}" == "" ]]; then
  echo "must supply an AMI to use for EC2 Instance"
  exit 1
fi

ami_id=${EC2_AMI}
instance_type=${EC2_INSTANCE_TYPE}
host_device_name="/dev/xvdc"

if [[ "$EC2_INSTANCE_TYPE" =~ a1.* ]] || [[ "$EC2_INSTANCE_TYPE" =~ c6g.* ]]; then
  host_device_name="/dev/nvme1n1"
fi

echo "ec2-user" > "${SHARED_DIR}/ssh_user"

echo -e "AMI ID: $ami_id"

# shellcheck disable=SC2154
cat > "${cf_tpl_file}" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for RHEL machine Launch

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.192.0.0/16
    Description: CIDR block for VPC.
    Type: String
  PublicSubnetCidr:
    Description: Please enter the IP range (CIDR notation) for the public subnet in the first Availability Zone
    Type: String
    Default: 10.192.10.0/24
  AmiId:
    Description: Current RHEL AMI to use.
    Type: AWS::EC2::Image::Id
  Machinename:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Machinename
    Description: Machinename
    Type: String
    Default: rhel-testbed-ec2-instance
  HostInstanceType:
    Default: t2.medium
    Type: String
  PublicKeyString:
    Type: String
    Description: The public key used to connect to the EC2 instance
  HostDeviceName:
    Type: String
    Description: Disk device name to create pvs and vgs

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Host Information"
      Parameters:
      - HostInstanceType
    - Label:
        default: "Network Configuration"
      Parameters:
      - PublicSubnet
    ParameterLabels:
      PublicSubnet:
        default: "Worker Subnet"
      HostInstanceType:
        default: "Worker Instance Type"

Resources:
## VPC Creation

  RHELVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      Tags:
        - Key: Name
          Value: RHELVPC

## Setup internet access

  RHELInternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: RHELInternetGateway

  RHELGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref RHELVPC
      InternetGatewayId: !Ref RHELInternetGateway

  RHELPublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref RHELVPC
      CidrBlock: !Ref PublicSubnetCidr
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: RHELPublicSubnet

  RHELNatGatewayEIP:
    Type: AWS::EC2::EIP
    DependsOn: RHELGatewayAttachment
    Properties:
      Domain: vpc
  RHELNatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt RHELNatGatewayEIP.AllocationId
      SubnetId: !Ref RHELPublicSubnet

  RHELRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref RHELVPC
      Tags:
        - Key: Name
          Value: RHELRouteTable

  RHELPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: RHELGatewayAttachment
    Properties:
      RouteTableId: !Ref RHELRouteTable
      DestinationCidrBlock: "0.0.0.0/0"
      GatewayId: !Ref RHELInternetGateway

  RHELPublicSubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref RHELRouteTable
      SubnetId: !Ref RHELPublicSubnet

## Setup EC2 Roles and security

  RHELIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "ec2.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"

  RHELInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "RHELIamRole"

  RHELSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: RHEL Host Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: -1
        ToPort: -1
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5353
        ToPort: 5353
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5678
        ToPort: 5678
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6443
        ToPort: 6443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      - IpProtocol: udp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      VpcId: !Ref RHELVPC

  RHELInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      IamInstanceProfile: !Ref RHELInstanceProfile
      InstanceType: !Ref HostInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "True"
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt RHELSecurityGroup.GroupId
        SubnetId: !Ref RHELPublicSubnet
      Tags:
      - Key: Name
        Value: !Join ["", [!Ref Machinename]]
      BlockDeviceMappings:
      - DeviceName: /dev/sda1
        Ebs:
          VolumeSize: "120"
          VolumeType: gp2
      - DeviceName: /dev/sdc
        Ebs:
          VolumeSize: "120"
          VolumeType: gp3
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash -xe
          echo "\${PublicKeyString}" >> /home/ec2-user/.ssh/authorized_keys
          sudo dnf install -y lvm2

          # NOTE: wrappig script vars with {} since the cloudformation will see
          # them as cloudformation vars instead.
          sudo pvcreate "\${HostDeviceName}"
          sudo vgcreate rhel "\${HostDeviceName}"

Outputs:
  InstanceId:
    Description: RHEL Host Instance ID
    Value: !Ref RHELInstance
  PrivateIp:
    Description: The bastion host Private DNS, will be used for cluster install pulling release image
    Value: !GetAtt RHELInstance.PrivateIp
  PublicIp:
    Description: The bastion host Public IP, will be used for registering minIO server DNS
    Value: !GetAtt RHELInstance.PublicIp
EOF


echo -e "==== Start to create rhel host ===="
echo "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region "$REGION" cloudformation create-stack --stack-name "${stack_name}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HostInstanceType,ParameterValue="${instance_type}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=HostDeviceName,ParameterValue="${host_device_name}" \
        ParameterKey=PublicKeyString,ParameterValue="$(cat ${CLUSTER_PROFILE_DIR}/ssh-publickey)" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

echo "$stack_name" > "${SHARED_DIR}/rhel_host_stack_name"
# shellcheck disable=SC2016
INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
--query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-id"
# shellcheck disable=SC2016
HOST_PUBLIC_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
# shellcheck disable=SC2016
HOST_PRIVATE_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"

echo "${HOST_PUBLIC_IP}" > "${SHARED_DIR}/public_address"
echo "${HOST_PRIVATE_IP}" > "${SHARED_DIR}/private_address"

echo "Waiting up to 5 min for RHEL host to be up."
timeout 5m aws --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
