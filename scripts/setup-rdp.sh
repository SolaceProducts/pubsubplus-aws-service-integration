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
apiPath=""
apiStage=""
awsRegion=""
DEBUG="-vvvv"

verbose=0

while getopts "a:h:p:r:s:" opt; do
    case "$opt" in
    a)  apiGwId=$OPTARG
        ;;
    h)  apiPath=$OPTARG
        ;;
    p)  admin_password_file=$OPTARG
        ;;
    r)  awsRegion=$OPTARG
        ;;
    s)  apiStage=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))
[ "$1" = "--" ] && shift

verbose=1
echo "apiGwId=${apiGwId} ,apiStage=${apiStage} ,apiPath=${apiPath} \
      ,admin_password_file=$admin_password_file ,awsRegion=${awsRegion} ,Leftovers: $@"

export admin_password=`cat ${admin_password_file}`

echo "`date` INFO: Setting up aws trusted root"
wget -q -O /var/lib/docker/volumes/jail/_data/certs/AmazonRootCA1.pem -nv https://www.amazontrust.com/repository/AmazonRootCA1.pem

online_results=`/tmp/semp_query.sh -n admin -p ${admin_password} -u http://localhost:8080/SEMP \
    -q "<rpc semp-version='soltr/8_9VMR'><authentication><create><certificate-authority><ca-name>aws</ca-name></certificate-authority></create></authentication></rpc>" \
    -v "/rpc-reply/execute-result/@code"`
ca_created=`echo ${online_results} | jq '.valueSearchResult' -`
echo "`date` INFO: certificate-authority created status: ${ca_created}"

online_results=`/tmp/semp_query.sh -n admin -p ${admin_password} -u http://localhost:8080/SEMP \
    -q "<rpc semp-version='soltr/8_9VMR'><authentication><certificate-authority><ca-name>aws</ca-name><certificate><ca-certificate>AmazonRootCA1.pem</ca-certificate></certificate></certificate-authority></authentication></rpc>" \
    -v "/rpc-reply/execute-result/@code"`
ca_loaded=`echo ${online_results} | jq '.valueSearchResult' -`
echo "`date` INFO: certificate-authority file loaded status: ${ca_loaded}"

echo "`date` INFO: Setting up Solace Queue"
curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"queueName\":\"aws_service_${apiPath}_queue\",\"egressEnabled\":true,\"ingressEnabled\":true,\"permission\":\"delete\"}" \
    "http://localhost:8080/SEMP/v2/config/msgVpns/default/queues"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"msgVpnName\":\"default\",\"queueName\":\"aws_service_${apiPath}_queue\",\"subscriptionTopic\":\"test/${apiPath}/aws/service\"}" \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/queues/aws_service_${apiPath}_queue/subscriptions" 

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
     --data "{\"msgVpnName\":\"default\",\"postRequestTarget\":\"/${apiStage}/${apiPath}\",\"queueBindingName\":\"aws_service_${apiPath}_queue\",\"restDeliveryPointName\":\"aws_service_rpd\"}" \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/restDeliveryPoints/aws_service_rpd/queueBindings"

curl --user admin:${admin_password} \
     --request POST \
     --header "content-type:application/json" \
     --data "{\"enabled\":true,\"msgVpnName\":\"default\",\"remoteHost\":\"${apiGwId}.execute-api.${awsRegion}.amazonaws.com\",\"remotePort\":443,\"restConsumerName\":\"aws_service_rc\",\"tlsEnabled\":true}" \
     "http://localhost:8080/SEMP/v2/config/msgVpns/default/restDeliveryPoints/aws_service_rpd/restConsumers"


