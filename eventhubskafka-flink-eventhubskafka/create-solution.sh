#!/bin/bash

# Strict mode, fail on any error
set -euo pipefail

export PREFIX=''
export LOCATION="eastus"
export TESTTYPE="1"
export STEPS="CIPTM"
export FLINK_PLATFORM='aks'
export FLINK_JOBTYPE='simple-relay'

usage() {
    echo "Usage: $0 -d <deployment-name> [-s <steps>] [-t <test-type>] [-l <location>] [-p <platform>]"
    echo "-s: specify which steps should be executed. Default=$STEPS"
    echo "    Possible values:"
    echo "      C=COMMON"
    echo "      I=INGESTION"
    echo "      P=PROCESSING"
    echo "      T=TEST clients"
    echo "      M=METRICS reporting"
    echo "      V=VERIFY deployment"
    echo "-t: test 1,5,10 thousands msgs/sec. Default=$TESTTYPE"
    echo "-p: platform: aks or hdinsight. Default=$FLINK_PLATFORM"
    echo "-a: type of job: 'simple-relay' or 'complex-processing'. Default=$FLINK_JOBTYPE"
    echo "-l: where to create the resources. Default=$LOCATION"
    exit 1;
}

# Initialize parameters specified from command line
while getopts ":d:s:t:l:p:a:" arg; do
	case "${arg}" in
		d)
			PREFIX=${OPTARG}
			;;
		s)
			STEPS=${OPTARG}
			;;
		t)
			TESTTYPE=${OPTARG}
			;;
		l)
			LOCATION=${OPTARG}
			;;
		p)
			FLINK_PLATFORM=${OPTARG}
			;;
		a)
			FLINK_JOBTYPE=${OPTARG}
			;;
		esac
done
shift $((OPTIND-1))

if [[ -z "$PREFIX" ]]; then
	echo "Enter a name for this deployment."
	usage
fi

export AKS_KUBERNETES_VERSION=1.14.7

# 10000 messages/sec
if [ "$TESTTYPE" == "10" ]; then
    export EVENTHUB_CAPACITY=12
    export EVENTHUB_PARTITIONS=8
    export FLINK_PARALLELISM=8
    export SIMULATOR_INSTANCES=5
    # settings for AKS (-p aks)
    export AKS_NODES=4
    export AKS_VM_SIZE=Standard_D4s_v3
    # settings for HDInsight YARN (-p hdinsight)
    export HDINSIGHT_HADOOP_WORKERS=3
    export HDINSIGHT_HADOOP_WORKER_SIZE=Standard_D3_V2
fi

# 5000 messages/sec
if [ "$TESTTYPE" == "5" ]; then
    export EVENTHUB_CAPACITY=6
    export EVENTHUB_PARTITIONS=4
    export FLINK_PARALLELISM=4
    export SIMULATOR_INSTANCES=3
    # settings for AKS (-p aks)
    export AKS_NODES=5
    export AKS_VM_SIZE=Standard_D2s_v3
    # settings for HDInsight YARN (-p hdinsight)
    export HDINSIGHT_HADOOP_WORKERS=3
    export HDINSIGHT_HADOOP_WORKER_SIZE=Standard_D3_V2
fi

# 1000 messages/sec
if [ "$TESTTYPE" == "1" ]; then
    export EVENTHUB_CAPACITY=2
    export EVENTHUB_PARTITIONS=1
    export FLINK_PARALLELISM=1
    export SIMULATOR_INSTANCES=1
    # settings for AKS (-p aks)
    export AKS_NODES=3
    export AKS_VM_SIZE=Standard_D2s_v3
    # settings for HDInsight YARN (-p hdinsight)
    export HDINSIGHT_HADOOP_WORKERS=3
    export HDINSIGHT_HADOOP_WORKER_SIZE=Standard_D3_V2
fi

# last checks and variables setup
if [ -z ${SIMULATOR_INSTANCES+x} ]; then
    usage
fi

export RESOURCE_GROUP=$PREFIX
export IMAGE_TAG=$PREFIX$(date +%s)

# remove log.txt if exists
rm -f log.txt

echo "Checking pre-requisites..."

source ../assert/has-local-az.sh
source ../assert/has-local-jq.sh
source ../assert/has-local-helm.sh
source ../assert/has-local-kubectl.sh
source ../assert/has-local-mvn.sh

echo
echo "Streaming at Scale with Flink"
echo "============================="
echo

echo "Steps to be executed: $STEPS"
echo

echo "Configuration: "
echo ". Resource Group      => $RESOURCE_GROUP"
echo ". Region              => $LOCATION"
echo ". EventHubs           => TU: $EVENTHUB_CAPACITY, Partitions: $EVENTHUB_PARTITIONS"
if [ "$FLINK_PLATFORM" == "hdinsight" ]; then
  echo ". HDInsight YARN      => VM: $HDINSIGHT_HADOOP_WORKER_SIZE, Workers: $HDINSIGHT_HADOOP_WORKERS"
else
  echo ". AKS                 => VM: $AKS_VM_SIZE, Workers: $AKS_NODES"
fi
echo ". Flink               => AKS nodes: $AKS_NODES x $AKS_VM_SIZE, Parallelism: $FLINK_PARALLELISM"
echo ". Simulators          => $SIMULATOR_INSTANCES"
if [[ -n ${AD_SP_APP_ID:-} && -n ${AD_SP_SECRET:-} ]]; then
    echo ". Service Principal   => $AD_SP_APP_ID"
fi
echo

echo "Deployment started..."
echo

echo "***** [C] Setting up COMMON resources"

    export AZURE_STORAGE_ACCOUNT=$PREFIX"storage"
    export VNET_NAME=$PREFIX"-vnet"

    RUN=`echo $STEPS | grep C -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/azure-common/create-resource-group.sh
        source ../components/azure-storage/create-storage-account.sh
        source ../components/azure-common/create-virtual-network.sh
    fi
echo

echo "***** [I] Setting up INGESTION"

    export KAFKA_TOPIC="in"
    export KAFKA_OUT_TOPIC="out"
    export EVENTHUB_NAMESPACE=$PREFIX"eventhubs"
    export EVENTHUB_NAMESPACE_OUT=$PREFIX"eventhubsout"
    export EVENTHUB_NAMESPACES="$EVENTHUB_NAMESPACE $EVENTHUB_NAMESPACE_OUT"
    export EVENTHUB_NAMES="$KAFKA_TOPIC $KAFKA_OUT_TOPIC"
    export EVENTHUB_CG="verify"
    export EVENTHUB_ENABLE_KAFKA="true"

    RUN=`echo $STEPS | grep I -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/azure-event-hubs/create-event-hub.sh
    fi
echo

echo "***** [P] Setting up PROCESSING"

    export APPINSIGHTS_NAME=$PREFIX"appmon"
    # Creating multiple HDInsight clusters in the same Virtual Network requires each cluster to have unique first six characters.
    export HDINSIGHT_YARN_NAME="yarn"$PREFIX"hdi"
    export HDINSIGHT_PASSWORD="Strong_Passw0rd!"
    export AKS_CLUSTER=$PREFIX"aks"
    export SERVICE_PRINCIPAL_KV_NAME=$AKS_CLUSTER
    export SERVICE_PRINCIPAL_KEYVAULT=$PREFIX"spkv"
    export ACR_NAME=$PREFIX"acr"

    source ../components/azure-monitor/generate-workspace-name.sh

    RUN=`echo $STEPS | grep P -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/apache-flink/build-flink-jobs.sh
        source ../components/azure-event-hubs/get-eventhubs-kafka-brokers-in-listen.sh
        source ../components/azure-event-hubs/get-eventhubs-kafka-brokers-out-send.sh
        source ../components/apache-flink/$FLINK_PLATFORM/run-flink.sh 
    fi
echo

echo "***** [T] Starting up TEST clients"

    RUN=`echo $STEPS | grep T -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/azure-event-hubs/get-eventhubs-kafka-brokers.sh "$EVENTHUB_NAMESPACE" "Send"
        source ../simulator/run-generator-kafka.sh
    fi
echo

echo "***** [M] Starting METRICS reporting"

    RUN=`echo $STEPS | grep M -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/azure-event-hubs/report-throughput.sh
    fi
echo

echo "***** [V] Starting deployment VERIFICATION"

    export ADB_WORKSPACE=$PREFIX"databricks" 
    export ADB_TOKEN_KEYVAULT=$PREFIX"kv" #NB AKV names are limited to 24 characters
    export ALLOW_DUPLICATES=1

    RUN=`echo $STEPS | grep V -o || true`
    if [ ! -z "$RUN" ]; then
        source ../components/azure-databricks/create-databricks.sh
        export EVENTHUB_NAME="$KAFKA_OUT_TOPIC"
        source ../streaming/databricks/runners/verify-eventhubs.sh
    fi
echo

echo "***** Done"
