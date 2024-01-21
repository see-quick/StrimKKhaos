#!/bin/bash

# Mandatory environment variables
PROMETHEUS_URL="${PROMETHEUS_URL:-http://default-prometheus-url}" # Replace 'http://default-prometheus-url' with your default Prometheus URL

#####################################################################################################################
################################# CHAOS MESH INSTALL/UNINSTALL  #####################################################
#####################################################################################################################

# Function to install Chaos Mesh using Helm and verify that all pods are running
install_chaos_mesh() {
    local release_name=$1
    local namespace=$2
    local cm_version=$3
    local openshift_flag=$4

    # Check if the namespace exists, create if not
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        echo_warning "Namespace $namespace does not exist. Creating it..."
        kubectl create namespace "$namespace"
        echo_success "Namespace $namespace created."
    fi

    echo "Installing Chaos Mesh version $cm_version in namespace $namespace with release name $release_name"
    # Installation command (using Helm)
    helm install $release_name chaos-mesh/chaos-mesh -n $namespace \
        --set chaosDaemon.runtime=crio \
        --set chaosDaemon.socketPath=/var/run/crio/crio.sock \
        --set chaosDaemon.env.RUST_BACKTRACE=full \
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

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  --install                  Install Chaos Mesh"
    echo "  --uninstall                Uninstall Chaos Mesh"
    echo "  --pod-chaos                Apply a PodChaos experiment"
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

#####################################################################################################################
################################################ POD CHAOS  #########################################################
#####################################################################################################################

############################################### KILLING LEADER ######################################################

# Function to apply PodChaos
apply_podchaos() {
    local template_yaml="./chaos-manifests/pod_chaos/kafka_random_pod_kill.yaml"
    local experiment_name=$(generate_experiment_name)

    # Check if the template YAML file exists
    if [ ! -f "$template_yaml" ]; then
        echo_error "PodChaos template YAML file does not exist at path: $template_yaml"
        return 1
    fi

    sed -i '' "s/name: .*/name: $experiment_name/" "$template_yaml"

    echo "Applying PodChaos from YAML manifest: $template_yaml"
    kubectl apply -f "$template_yaml"

    echo_success "PodChaos applied using manifest $template_yaml."
}

# Function to check if the PodChaos experiment has started
check_podchaos_started() {
    # Get the status of the PodChaos object
    pod_chaos_status=$(oc get PodChaos kafka-random-pod-kill -n strimzi-kafka -o json)

    # Check if AllInjected is True
    all_injected=$(echo "$pod_chaos_status" | jq -r '.status.conditions[] | select(.type=="AllInjected") | .status')

    # Check the desiredPhase
    desired_phase=$(echo "$pod_chaos_status" | jq -r '.status.experiment.desiredPhase')

    # Determine if the experiment has started
    if [[ "$all_injected" == "True" && "$desired_phase" == "Run" ]]; then
        echo_success "PodChaos experiment has started."
    else
        echo_warning "PodChaos experiment has not started or is completed."
    fi
}

# Function to scrape Prometheus metrics at regular intervals
scrape_metrics_during_chaos() {
    local query_expr=$1
    local interval=$2
    local duration=$3
    local end_time=$((SECONDS + duration))
    local total=0
    local count=0

    while [ $SECONDS -lt $end_time ]; do
        local result=$(curl -s -G --data-urlencode "query=$query_expr" "$PROMETHEUS_URL/api/v1/query" | jq -r '.data.result[0].value[1]')
        total=$(echo "$total + $result" | bc)
        count=$((count + 1))
        sleep $interval
    done

    if [ $count -gt 0 ]; then
        local average=$(echo "$total / $count" | bc -l)
        local round_average_two_decimals=$(round $average)
        echo "$round_average_two_decimals"
    else
        echo_error "No metrics scraped."
        return 1
    fi
}

# Function to create Prometheus query expression with customizable time range
build_query_expr() {
    local time_range=$1
    local function_name="rate"

    if [[ $time_range == "1m" ]]; then
        function_name="irate" # Use irate for short time range because, it calculates the rate of increase using the last two points in the provided range
    fi

    echo "sum(${function_name}(kafka_server_brokertopicmetrics_messagesin_total{namespace=\"strimzi-kafka\",strimzi_io_cluster=\"anubis\",topic=~\".+\",topic!=\"\",kubernetes_pod_name=~\"anubis-.*\", clusterName=~\"worker-01\"}[${time_range}]))"
}

round() {
  printf "%.2f" "$(echo "scale=2; $1/1" | bc -l)"
}

# Function to verify decrease in Kafka throughput
verify_kafka_throughput() {
    local kafka_query_expr=$(build_query_expr "1h")

    # NORMAL AVERAGE compute based on 1h
    local normal_average=$(curl -s -G --data-urlencode "query=$kafka_query_expr" "$PROMETHEUS_URL/api/v1/query" | jq -r '.data.result[0].value[1]')
    echo "Normal average of messages in the past hour is $normal_average"

    kafka_query_expr=$(build_query_expr "5m")

    local scrape_interval=1
    local chaos_duration=300 # Duration of chaos experiment in seconds
    local chaos_average=$(scrape_metrics_during_chaos "$kafka_query_expr" $scrape_interval $chaos_duration)

    normal_average=$(round $normal_average)

    # Perform the comparison using bc
    result=$(echo "${chaos_average} < ${normal_average}" | bc -l)

    if [[ $result -eq 1 ]]; then
        echo_success "Verified expected decrease in Kafka throughput after chaos experiment: chaos average msg/s is ${chaos_average} which is lower than normal average i.e., ${normal_average}"
    else
        echo_error "Kafka throughput did not decrease as expected: chaos average msg/s is ${chaos_average} which is greater than normal average i.e., ${normal_average}"
    fi
}

# Function to generate the next experiment name
generate_experiment_name() {
    local base_name="kafka-kill-random-leader"

    # Get the list of existing PodChaos objects with the base name
    local existing_names=$(kubectl get PodChaos -n strimzi-kafka -o jsonpath="{.items[?(@.metadata.name startsWith ${base_name})].metadata.name}")

    # Find the highest number used so far
    local max_number=-1
    for name in $existing_names; do
        local number=$(echo "$name" | sed -e "s/^${base_name}-//")
        if [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -gt "$max_number" ]; then
            max_number=$number
        fi
    done

    # Generate the next number
    local next_number=$((max_number + 1))

    # Construct the full experiment name
    echo "${base_name}-${next_number}"
}

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################


#####################################################################################################################
########################################### AUXILIARY METHODS #######################################################
#####################################################################################################################

# Function to check if Chaos Mesh is installed
check_chaos_mesh() {
    if ! kubectl get crd podchaos.chaos-mesh.org >/dev/null 2>&1; then
        echo_warning "Chaos Mesh is not installed. Installing it now..."
        install_chaos_mesh
    else
        echo_success "Chaos Mesh is installed."
    fi
}

# Main function to parse arguments and execute commands
main() {
    local install_flag=false
    local uninstall_flag=false
    local openshift_flag=false
    local pod_chaos_flag=false

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
               echo_error "Unknown option $key"
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

    if $pod_chaos_flag; then
        apply_podchaos

        check_podchaos_started

        verify_kafka_throughput
    fi
}

# Call main function with all passed arguments
main "$@"

echo_success "Chaos testing script execution completed."
