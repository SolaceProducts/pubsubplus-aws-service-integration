#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
admin_password_file=""
apiGwId=""
awsRegion=""
disk_size=""
volume=""
DEBUG="-vvvv"

verbose=0

while getopts "a:p:r:s:v:" opt; do
    case "$opt" in
    a)  apiGwId=$OPTARG
        ;;
    p)  admin_password_file=$OPTARG
        ;;
    r)  awsRegion=$OPTARG
        ;;
    s)  disk_size=$OPTARG
        ;;
    v)  volume=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))
[ "$1" = "--" ] && shift

verbose=1
echo "apiGwId=${apiGwId} , admin_password_file=$admin_password_file , disk_size=$disk_size , \
      awsRegion=${awsRegion} ,volume=$volume , Leftovers: $@"

export admin_password=`cat ${admin_password_file}`
export STAGE="DEVELOPMENT"
export API_PATH="send"

echo "`date` INFO: Set Docker up IPTables and Device Driver"
service docker stop
echo 'OPTIONS="--iptables=false --storage-driver=devicemapper"' >> /etc/sysconfig/docker
service docker start

# Memory setup for when using smaller instance-types
echo "`date` INFO: Set up swap for < 6GB machines"
MEM_SIZE=`cat /proc/meminfo | grep MemTotal | tr -dc '0-9'`
if [ ${MEM_SIZE} -lt 6087960 ]; then
 echo "`date` WARN: Not enough memory: ${MEM_SIZE} Creating 2GB Swap space"
 mkdir /var/lib/solace
 dd if=/dev/zero of=/var/lib/solace/swap count=2048 bs=1MiB
 mkswap -f /var/lib/solace/swap
 chmod 0600 /var/lib/solace/swap
 swapon -f /var/lib/solace/swap
 grep -q 'solace\/swap' /etc/fstab || sudo sh -c 'echo "/var/lib/solace/swap none swap sw 0 0" >> /etc/fstab'
else
  echo "`date` INFO: Memory size is ${MEM_SIZE}"
fi

# Make sure Docker is actually up
docker_running=""
loop_guard=6
loop_count=0
while [ ${loop_count} != ${loop_guard} ]; do
    sleep 10
    docker_running=`service docker status | grep -o running`
    if [ ${docker_running} != "running" ]; then
        ((loop_count++))
        echo "`date` WARN: Tried to launch Solace but Docker in state ${docker_running}"
    else
        echo "`date` INFO: Docker in state ${docker_running}"
        break
    fi
done

echo "`date` INFO: Get latest Standard edition SolOS"
docker pull solace/solace-pubsub-standard

export VMR_VERSION=`docker images | grep solace | awk '{print $3}'`

host_name=`hostname`

echo "`date` INFO: Set up external disk if required"
if [ $disk_size == "0" ]; then
   SPOOL_MOUNT="-v internalSpool:/usr/sw/internalSpool -v adbBackup:/usr/sw/adb -v softAdb:/usr/sw/internalSpool/softAdb"
else
    echo "`date` Create primary partition on new disk"
    (
    echo n # Add a new partition
    echo p # Primary partition
    echo 1  # Partition number
    echo   # First sector (Accept default: 1)
    echo   # Last sector (Accept default: varies)
    echo w # Write changes
    ) | sudo fdisk $volume

    mkfs.xfs  ${volume}1 -m crc=0
    UUID=`blkid -s UUID -o value ${volume}1`
    echo "UUID=${UUID} /opt/vmr xfs defaults 0 0" >> /etc/fstab
    mkdir /opt/vmr
    mount -a
    SPOOL_MOUNT="-v /opt/vmr:/usr/sw/internalSpool -v /opt/vmr:/usr/sw/adb -v /opt/vmr:/usr/sw/internalSpool/softAdb"
fi

# Start up the SolOS docker instance with HA config keys
echo "`date` INFO: Executing 'docker create'"
docker create \
   --network=host \
   --uts=host \
   --shm-size 2g \
   --ulimit core=-1 \
   --ulimit memlock=-1 \
   --ulimit nofile=2448:42192 \
   --restart=always \
   -v jail:/usr/sw/jail \
   -v var:/usr/sw/var \
   -v /mnt/vmr/secrets:/run/secrets \
   ${SPOOL_MOUNT} \
   --env "username_admin_globalaccesslevel=admin" \
   --env "username_admin_passwordfilepath=$(basename ${admin_password_file})" \
   --env "service_ssh_port=2222" \
   --name=solace ${VMR_VERSION}

# Start the solace service and enable it at system start up.
chkconfig --add solace-vmr
echo "`date` INFO: Starting Solace service"
service solace-vmr start

# Poll the VMR SEMP port until it is Up
loop_guard=30
pause=10
count=0
echo "`date` INFO: Wait for the VMR SEMP service to be enabled"
while [ ${count} -lt ${loop_guard} ]; do
  online_results=`/tmp/semp_query.sh -n admin -p ${admin_password} -u http://localhost:8080/SEMP \
    -q "<rpc semp-version='soltr/8_9VMR'><show><service/></show></rpc>" \
    -v "/rpc-reply/rpc/show/service/services/service[name='SEMP']/enabled[text()]"`
  is_vmr_up=`echo ${online_results} | jq '.valueSearchResult' -`
  echo "`date` INFO: SEMP service 'enabled' status is: ${is_vmr_up}"
  run_time=$((${count} * ${pause}))
  if [ "${is_vmr_up}" = "\"true\"" ]; then
      echo "`date` INFO: VMR SEMP service is up, after ${run_time} seconds"
      break
  fi
  ((count++))
  echo "`date` INFO: Waited ${run_time} seconds, VMR SEMP service not yet up"
  sleep ${pause}
done

echo "`date` INFO: Setting up aws trusted root"
wget -q -O /var/lib/docker/volumes/jail/_data/certs/AmazonRootCA1.pem -nv https://www.amazontrust.com/repository/AmazonRootCA1.pem

online_results=`/tmp/semp_query.sh -n admin -p ${admin_password} -u http://localhost:8080/SEMP \
    -q "<rpc semp-version='soltr/8_9VMR'><authentication><create><certificate-authority><ca-name>aws</ca-name></certificate-authority></create></authentication></rpc>" \
    -v "/rpc-reply/execute-result/@code"`
ca_created=`echo ${online_results} | jq '.valueSearchResult' -`
echo "`date` INFO: certificate-authority created status: ${ca_created}"

online_results=`/tmp/semp_query.sh -n admin -p ${admin_password} -u http://localhost:8080/SEMP \
    -q "<rpc semp-version='soltr/8_9VMR'><authentication><certificate-authority><ca-name>aws</ca-name><certificate><ca-certificate>certs/AmazonRootCA1.pem</ca-certificate></certificate></certificate-authority></authentication></rpc>" \
    -v "/rpc-reply/execute-result/@code"`
ca_loaded=`echo ${online_results} | jq '.valueSearchResult' -`
echo "`date` INFO: certificate-authority file loaded status: ${ca_loaded}"

echo "`date` INFO: Setting up Solace Queue"
curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data '{"queueName":"aws_service_queue","egressEnabled":true,"ingressEnabled":true,"permission":"delete"}' \
    "http://localhost:8080/SEMP/v2/config/msgVpns/default/queues"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data '{"msgVpnName":"default","queueName":"aws_service_queue","subscriptionTopic":"test/to/aws/service"}' \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/queues/aws_service_queue/subscriptions" 

echo "`date` INFO: Setting up Rest Delivery Endpoint"
curl --user admin:${admin_password} \
     --request PATCH \
     --header "content-type:application/json" \
     --data '{"msgVpnName":"default","restTlsServerCertEnforceTrustedCommonNameEnabled":false}' \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data '{"enabled":true,"msgVpnName":"default","restDeliveryPointName":"aws_service_rpd"}' \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/restDeliveryPoints"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"default\",\"postRequestTarget\":\"${STAGE}/${API_PATH}\",\"queueBindingName\":\"aws_service_queue\",\"restDeliveryPointName\":\"aws_service_rpd\"}" \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/restDeliveryPoints/aws_service_rpd/queueBindings"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"enabled\":true,\"msgVpnName\":\"default\",\"remoteHost\":\"${apiGwId}.execute-api.${awsRegion}.amazonaws.com\",\"remotePort\":443,\"restConsumerName\":\"aws_service_rc\",\"tlsEnabled\":true}" \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/restDeliveryPoints/aws_service_rpd/restConsumers"

# Remove all VMR Secrets from the host; at this point, the VMR should have come up
# and it won't be needing those files anymore
rm ${admin_password_file}

if [ ${count} -eq ${loop_guard} ]; then
  echo "`date` ERROR: Solace VMR SEMP service never came up" | tee /dev/stderr
  exit 1
fi

