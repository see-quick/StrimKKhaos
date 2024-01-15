#!/bin/bash

# Basic Chaos Testing Script for Strimzi using Chaos Mesh in OpenShift

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  --install                  Install Chaos Mesh"
    echo "  --uninstall                Uninstall Chaos Mesh"
    echo "  --pod-chaos                Apply a PodChaos experiment"
    echo "  --network-chaos            Apply a NetworkChaos experiment"
    echo "  --monitor-log              Monitor and log Chaos Mesh activities"
    echo "  --cleanup                  Cleanup after experiment"
    echo "  --release-name NAME        Specify the release name for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --namespace NS             Specify the namespace for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --version VER              Specify the version of Chaos Mesh (default: '2.6.2')"
    echo "  --openshift                Indicate that the script is running in an OpenShift environment"
    echo ""
    echo "Example:"
    echo "  $0 --install --release-name my-chaos --namespace my-namespace --version 2.6.2"
}

# Function to echo success messages in green with a [SUCCESS] prefix
echo_success() {
    echo -e "\033[0;32m[SUCCESS] $1\033[0m"
}

# Function to echo warning messages in yellow with a [WARNING] prefix
echo_warning() {
    echo -e "\033[0;33m[WARNING] $1\033[0m"
}

# Function to echo error messages in red with an [ERROR] prefix
echo_error() {
    echo -e "\033[0;31m[ERROR] $1\033[0m"
}

# Function to deploy Kafka producers
deploy_kafka_producers() {
    for i in {1..10}; do
        kubectl apply -f <(sed "s/{{INDEX}}/$i/g" chaos-manifests/producer/producer.yaml) -n myproject
    done
    echo_success "Kafka producers deployed."
}

# Function to delete Kafka producers
delete_kafka_producers() {
    for i in {1..10}; do
        kubectl delete job kafka-producer-client-$i -n myproject
    done
    echo_success "Kafka producers deleted."
}

# Function to query Prometheus from inside a Kafka pod using label
query_prometheus_from_pod() {
    local namespace=$1
    local label=$2
    local prometheus_url=$3
    local query=$4

    # Get the pod name dynamically based on label
    local pod_name=$(get_pod_name_by_label "$namespace" "$label")
    if [ -z "$pod_name" ]; then
        echo_error "No pod found with label $label in namespace $namespace"
        return 1
    fi

    # Executing the query inside the Kafka pod
    kubectl exec "$pod_name" -n "$namespace" -- curl -G --data-urlencode "query=$query" "$prometheus_url/api/v1/query"
}

# Function to get pod name by label
get_pod_name_by_label() {
    local namespace=$1
    local label=$2
    kubectl get pods -n "$namespace" -l "$label" -o jsonpath='{.items[0].metadata.name}'
}

# Function to install Chaos Mesh using Helm and verify that all pods are running
install_chaos_mesh() {
    local release_name=$1
    local namespace=$2
    local cm_version=$3
    local openshift_flag=$4

    echo "Installing Chaos Mesh version $cm_version in namespace $namespace with release name $release_name"
    # Installation command (using Helm)
    helm install $release_name chaos-mesh/chaos-mesh -n $namespace \
        --set chaosDaemon.runtime=crio \
        --set chaosDaemon.socketPath=/var/run/crio/crio.sock \
        --set chaosDaemon.env.RUST_BACKTRACE=full \
        # this is for debugging IOChaos (i.e., TODA tool)
        --version $cm_version

    # Wait for all Chaos Mesh pods to be running
    local retry_count=0
    local max_retries=20
    local sleep_duration=10
    local all_pods_running=false

    while [ $retry_count -lt $max_retries ]; do
        if kubectl get pods -n $namespace | grep 'chaos' | grep -q 'Running'; then
            all_pods_running=true
            break
        fi
        echo "Waiting for Chaos Mesh pods to be running... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_running; then
        echo_success "Chaos Mesh installed successfully and all pods are running."
    else
        echo_error "Failed to verify the startup of all Chaos Mesh pods. Please check manually."
        exit 1
    fi

    if [ "$openshift_flag" = true ]; then
        if ! oc get scc privileged -o jsonpath='{.users[]}' | grep -q "system:serviceaccount:$namespace:chaos-daemon"; then
            oc adm policy add-scc-to-user privileged system:serviceaccount:$namespace:chaos-daemon
            echo_success "Added 'privileged' SCC to 'chaos-daemon' service account."
        else
            echo_warning "'chaos-daemon' service account already has 'privileged' SCC. Skipping this step."
        fi
    fi
}

# Function to uninstall Chaos Mesh using Helm and verify that all pods are deleted
uninstall_chaos_mesh() {
    local release_name=$1
    local namespace=$2

    echo "Uninstalling Chaos Mesh with release name $release_name from namespace $namespace"
    # Uninstallation command (using Helm)
    helm uninstall $release_name -n $namespace

    # Wait for all Chaos Mesh pods to be deleted
    local retry_count=0
    local max_retries=20
    local sleep_duration=10
    local all_pods_deleted=false

    while [ $retry_count -lt $max_retries ]; do
        if ! kubectl get pods -n $namespace | grep -q 'chaos'; then
            all_pods_deleted=true
            break
        fi
        echo "Waiting for Chaos Mesh pods to be deleted... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_deleted; then
        echo_success "Chaos Mesh uninstalled successfully and all pods are deleted."
    else
        echo_error "Failed to verify the deletion of all Chaos Mesh pods. Please check manually."
        exit 1
    fi
}


# Function to check if Chaos Mesh is installed
check_chaos_mesh() {
    if ! kubectl get crd podchaos.chaos-mesh.org >/dev/null 2>&1; then
        echo_warning "Chaos Mesh is not installed. Installing it now..."
        install_chaos_mesh
    else
        echo_success "Chaos Mesh is installed."
    fi
}

# Function to apply a chaos experiment
apply_chaos_experiment() {
    local experiment_file=$1
    if [ -f "$experiment_file" ]; then
        echo "Applying chaos experiment from $experiment_file"
        kubectl apply -f "$experiment_file"
    else
        echo_error "Experiment file $experiment_file not found."
        exit 1
    fi
}

# Function to apply and monitor PodChaos experiment
apply_and_monitor_podchaos() {
    local experiment_file=$1
    local target_pod_label=$2
    local namespace=$3
    local experiment_duration=$4 # in seconds
    local experiment_name=$5

    # Apply the chaos experiment
    apply_chaos_experiment "$experiment_file"

    # Start monitoring
    monitor_and_log "$target_pod_label" "$namespace" "$experiment_duration" "$experiment_name"

    # Use chaosctl for additional diagnostics (example)
    echo "Using chaosctl for diagnostics"
    chaosctl logs -n $namespace
}

# Function to monitor and log results along with verifying the Chaos Mesh experiment status
monitor_and_log() {
    local target_pod_label=$1
    local namespace=$2
    local experiment_duration=$3 # in seconds
    local experiment_name=$4     # name of the chaos experiment

    echo "Starting PodChaos experiment monitoring at $(date)"
    local start_time=$(date +%s)
    local current_time=$start_time
    local end_time=$(($start_time + $experiment_duration))

    while [ $current_time -le $end_time ]; do
        echo "Checking pod status at $(date)..."
        kubectl get pods -n $namespace -l $target_pod_label

        echo "Verifying Chaos Mesh experiment status..."
        local experiment_status=$(kubectl get podchaos $experiment_name -n $namespace -o json)

         # Preprocess JSON output to escape control characters
        local cleaned_status=$(echo $experiment_status | tr -d '\n' | tr -d '\r')

        # Check if the JSON object is not null and has the expected structure
        if [[ ! -z "$cleaned_status" && $(echo $cleaned_status | jq -r '.status.conditions') != "null" ]]; then
            local all_injected=$(echo $cleaned_status | jq -r '.status.conditions[] | select(.type=="AllInjected") | .status')
            local all_recovered=$(echo $cleaned_status | jq -r '.status.conditions[] | select(.type=="AllRecovered") | .status')
            echo "Chaos Mesh Experiment Status: Injected: $all_injected, Recovered: $all_recovered"
        else
            echo_warning "Chaos Mesh Experiment status is not available or not ready."
        fi

        sleep 5
        current_time=$(date +%s)
    done

    echo_success "PodChaos experiment duration completed at $(date). Verifying pod recovery..."
    kubectl get pods -n $namespace -l $target_pod_label
}


# Function to cleanup Chaos Mesh experiment of a specific type
cleanup_chaos_experiment() {
    local experiment_type=$1
    local experiment_name=$2
    local namespace=$3

    echo "Cleaning up $experiment_type experiment $experiment_name from namespace $namespace..."
    kubectl delete $experiment_type $experiment_name -n $namespace

    # Check if the experiment is successfully deleted
    if kubectl get $experiment_type $experiment_name -n $namespace &> /dev/null; then
        echo_error "Failed to delete $experiment_type experiment $experiment_name."
        exit 1
    else
        echo_success "$experiment_type experiment $experiment_name successfully deleted."
    fi
}

# Main function to parse arguments and execute commands
main() {
    local install_flag=false
    local uninstall_flag=false
    local apply_experiment_flag=false
    local monitor_log_flag=false
    local cleanup_flag=false
    local openshift_flag=false
    local pod_chaos_flag=false
    local network_chaos_flag=false

   # Default values for variables
   local release_name="chaos-mesh"
   local namespace="chaos-mesh"
   local cm_version="2.6.2"

   if [[ $# -eq 0 ]]; then
       usage
       exit 1
   fi

   while [[ $# -gt 0 ]]; do
       key="$1"
       case "$key" in
           -h|--help)
               usage
               exit 0
               ;;
           --install)
               install_flag=true
               shift
               ;;
           --uninstall)
               uninstall_flag=true
               shift
               ;;
           --pod-chaos)
               pod_chaos_flag=true
               shift
               ;;
           --network-chaos)
               network_chaos_flag=true
               shift
               ;;
           --cleanup)
               cleanup_flag=true
               shift
               ;;
           --release-name)
               release_name="$2"
               shift
               shift
               ;;
           --namespace)
               namespace="$2"
               shift
               shift
               ;;
           --version)
               cm_version="$2"
               shift
               shift
               ;;
           --debug)
               set -xe
               shift
               ;;
           --openshift)
               openshift_flag=true
               shift
               ;;
           *)
               echo "Unknown option $key"
               usage
               exit 1
               ;;
       esac
    done

    # Execute commands based on flags
    if $install_flag; then
        install_chaos_mesh "$release_name" "$namespace" "$cm_version" "$openshift_flag"
    fi

    if $uninstall_flag; then
        uninstall_chaos_mesh "$release_name" "$namespace"
    fi

    # For PodChaos experiment (modify as per your needs)
    if $pod_chaos_flag; then
        apply_and_monitor_podchaos "./chaos-manifests/pod_chaos/pod-failure.yaml" "strimzi.io/kind=cluster-operator" "myproject" 300 "strimzi-operator-failure-example"
    fi

    # Example usage for cleanup
    if $cleanup_flag; then
        # TODO: make this as paramter now only podchaos
        cleanup_chaos_experiment "podchaos" "strimzi-operator-failure-example" "myproject"
        cleanup_chaos_experiment "networkchaos" "kafka-network-latency-all" "myproject"
    fi

    if $network_chaos_flag; then
        deploy_kafka_producers

        namespace="myproject"
        label="strimzi.io/kind=cluster-operator"  # Replace with the actual label of your Kafka pod
        prometheus_url="prometheus-operated:9090"
        metric_query="sum(irate(kafka_server_brokertopicmetrics_messagesin_total{namespace=\"$kubernetes_namespace\",strimzi_io_cluster=\"$strimzi_cluster_name\",topic=~\"$kafka_topic\",topic!=\"\",kubernetes_pod_name=~\"$strimzi_cluster_name-$kafka_broker\"}[1m]))"

        echo "Querying Prometheus before chaos..."
        query_result=$(query_prometheus_from_pod "$namespace" "$label" "$prometheus_url" "$metric_query")
        echo "Metrics before chaos: $query_result"

        apply_chaos_experiment "./chaos-manifests/network_chaos/network_latency_producers.yaml"

        echo "Monitoring metrics for 1 minutes..."
        sleep 60

        echo "Querying Prometheus after chaos..."
        query_result=$(query_prometheus_from_pod "$namespace" "$label" "$prometheus_url" "$metric_query")
        echo "Metrics after chaos: $query_result"

        delete_kafka_producers
    fi
}

# Call main function with all passed arguments
main "$@"

echo_success "Chaos testing script execution completed."
