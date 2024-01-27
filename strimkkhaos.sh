#!/bin/bash

# make script compatible with Linux-based system and also for MacOS
source ./common.sh

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
        --set chaosDaemon.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=1 \
        --set chaosDaemon.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=nodetype \
        --set chaosDaemon.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=In \
        --set chaosDaemon.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].values[0]=kafka \
        --set chaosDaemon.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].values[1]=connect \
        --set chaosDaemon.tolerations[0].key=nodetype \
        --set chaosDaemon.tolerations[0].operator=Equal \
        --set chaosDaemon.tolerations[0].value=kafka \
        --set chaosDaemon.tolerations[0].effect=NoSchedule \
        --set chaosDaemon.tolerations[1].key=nodetype \
        --set chaosDaemon.tolerations[1].operator=Equal \
        --set chaosDaemon.tolerations[1].value=connect \
        --set chaosDaemon.tolerations[1].effect=NoSchedule \
        --set chaosDaemon.tolerations[2].key=UpdateInProgress \
        --set chaosDaemon.tolerations[2].operator=Exists \
        --set chaosDaemon.tolerations[2].effect=PreferNoSchedule \
          --version $cm_version

    # Wait for all Chaos Mesh pods to be running
    local retry_count=0
    local max_retries=20
    local sleep_duration=10
    local all_pods_running=false

    while [ $retry_count -lt $max_retries ]; do
        if kubectl get pods -n $namespace | $GREP 'chaos' | $GREP -q 'Running'; then
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
        if ! oc get scc privileged -o jsonpath='{.users[]}' | $GREP -q "system:serviceaccount:$namespace:chaos-daemon"; then
            oc adm policy add-scc-to-user privileged system:serviceaccount:$namespace:chaos-daemon
            echo_success "Added 'privileged' SCC to 'chaos-daemon' service account."
        else
            echo_warning "'chaos-daemon' service account already has 'privileged' SCC. Skipping this step."
        fi
    fi

    # This has to be here until fixed https://github.com/chaos-mesh/chaos-mesh/issues/4313
    # Get all chaos-daemon pod names
    daemon_pods=$(kubectl get pods -n chaos-mesh -o custom-columns=:metadata.name --no-headers | grep chaos-daemon)

    # Loop over each daemon pod and execute the modprobe command
    for pod in $daemon_pods; do
      echo "Executing modprobe ebtables on pod: $pod"
      kubectl exec -n chaos-mesh "$pod" -- modprobe ebtables
    done

    echo_success "All daemon pods have been processed."
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
        if ! kubectl get pods -n $namespace | $GREP -q 'chaos'; then
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

#####################################################################################################################
################################################ POD CHAOS ##########################################################
#####################################################################################################################

############################################### KILLING LEADER ######################################################

# Function to apply PodChaos
# $1 - experiment name
apply_podchaos() {
    local template_yaml="./chaos-manifests/pod_chaos/anubis_kafka_kill_random_pod.yaml"

    apply_chaos $template_yaml "$1"
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
        total=$(echo "$total $result" | awk '{print $1 + $2}')
        count=$((count + 1))
        sleep $interval
    done

    if [ $count -gt 0 ]; then
        local average=$(echo "$total $count" | awk '{print $1 / $2}')
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

    if [[ $time_range == "5m" ]]; then
        function_name="irate" # Use irate for short time range because, it calculates the rate of increase using the last two points in the provided range
    fi

    echo "sum(${function_name}(kafka_server_brokertopicmetrics_messagesin_total{namespace=\"strimzi-kafka\",strimzi_io_cluster=\"anubis\",topic=~\".+\",topic!=\"\",kubernetes_pod_name=~\"anubis-.*\", clusterName=~\"worker-01\"}[${time_range}]))"
}

round() {
    echo "$1" | awk '{printf "%.2f", $1}'
}

# Function to verify decrease in Kafka throughput
verify_kafka_throughput() {
    local kafka_query_expr=$(build_query_expr "1h")

    # NORMAL AVERAGE compute based on 1h
    local normal_average=$(curl -s -G --data-urlencode "query=$kafka_query_expr" "$PROMETHEUS_URL/api/v1/query" | jq -r '.data.result[0].value[1]')
    normal_average=$(round $normal_average)
    echo "Normal average of messages in the past hour is $normal_average"

    kafka_query_expr=$(build_query_expr "5m")

    local scrape_interval=1
    local chaos_duration=300 # Duration of chaos experiment in seconds
    local chaos_average=$(scrape_metrics_during_chaos "$kafka_query_expr" $scrape_interval $chaos_duration)

    # Perform the comparison using awk
    result=$(echo "$chaos_average $normal_average" | awk '{print ($1 < $2) ? "1" : "0"}')


    if [[ $result -eq 1 ]]; then
        echo_success "Verified expected decrease in Kafka throughput after chaos experiment: chaos average msg/s is ${chaos_average} which is lower than normal average i.e., ${normal_average}"
    else
        echo_error "Kafka throughput did not decrease as expected: chaos average msg/s is ${chaos_average} which is greater than normal average i.e., ${normal_average}"
        exit 1
    fi
}

# Function to list all Chaos experiments from YAML files
# $1 - directory name (e.g., pod_chaos, network_chaos, http_chaos)
list_chaos() {
    echo_warning "You did not specify a concrete pod chaos"
    echo "The list of the supported $1 are: "

    local directory="./chaos-manifests/$1"
    local files=("$directory"/*.yaml)

    if [ -d "$directory" ] && [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            if [ -f "$file" ]; then
                experiment_name=$($GREP 'name:' "$file" | awk '{print $2}' | head -1)
                echo "- $experiment_name"
            fi
        done
    else
        echo "No $1 YAML files found in $directory."
    fi
}

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

#####################################################################################################################
############################################## NETWORK CHAOS ########################################################
#####################################################################################################################

################################### PRODUCER FAST INTERNAL NETWORK DELAY ############################################

# $1 - unique experiment name
apply_network_chaos_delay_to_internal_producers() {
    local template_yaml="./chaos-manifests/network_chaos/anubis_kafka_producers_fast_internal_network_delay_all.yaml"

    apply_chaos $template_yaml "$1"
}

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

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help                          Show this help message"
    echo "  --install                           Install Chaos Mesh"
    echo "  --uninstall                         Uninstall Chaos Mesh"
    echo "  --pod-chaos experiment_name         Apply a specific PodChaos experiment"
    echo "  --network-chaos experiment_name     Apply a specific NetworkChaos experiment"
    echo "  --release-name NAME                 Specify the release name for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --namespace NS                      Specify the namespace for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --version VER                       Specify the version of Chaos Mesh (default: '2.6.2')"
    echo "  --openshift                         Indicate that the script is running in an OpenShift environment"
    echo ""
    echo "Example:"
    echo "  $0 --install --release-name my-chaos --namespace my-namespace --version 2.6.2"
    echo "  $0 --pod-chaos anubis-kafka-kill-all-pods"
    echo "  $0 --network-chaos anubis-kafka-producers-fast-internal-network-delay-all"
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

apply_chaos() {
    local template_yaml=$1
    local experiment_name=$2

    # Check if the template YAML file exists
    if [ ! -f "$template_yaml" ]; then
        echo_error "Chaos template YAML file does not exist at path: $template_yaml"
        return 1
    fi

    $SED -i "s/name: .*/name: $experiment_name/" "$template_yaml"

    echo "Applying Chaos from YAML manifest: $template_yaml"
    kubectl apply -f "$template_yaml"

    echo_success "Chaos applied using manifest $template_yaml."
}

# Function to check if the Chaos experiment has started and wait until it does, with a 5-minute timeout
# $1 - experiment name
# $2 - chaos type (e.g., PodChaos, NetworkChaos)
# $3 - chaos namespace
check_chaos_started() {
    max_wait=300 # Maximum wait time of 5 minutes (300 seconds)
    elapsed_time=0 # Counter to keep track of the elapsed time
    sleep_duration=5 # Initial sleep duration in seconds

    while [ $elapsed_time -lt $max_wait ]; do
        # Get the status of the PodChaos object
        chaos_status=$(kubectl get $2 $1 -n $3 -o json)

        # Check if AllInjected is True
        all_injected=$(echo "$chaos_status" | jq -r '.status.conditions[] | select(.type=="AllInjected") | .status')

        # Check the desiredPhase
        desired_phase=$(echo "$chaos_status" | jq -r '.status.experiment.desiredPhase')

        # Determine if the experiment has started
        if [[ "$all_injected" == "True" && "$desired_phase" == "Run" ]]; then
            echo_success "{$2} experiment has started."
            return
        else
            echo "Waiting for {$2} experiment to start... Next check in $sleep_duration seconds."
            sleep $sleep_duration

            # Update the elapsed time and increase the sleep duration for the next iteration
            elapsed_time=$((elapsed_time + sleep_duration))
            sleep_duration=$((sleep_duration + 5)) # Increase sleep duration by 5 seconds each time

            # Cap the sleep_duration to not exceed the remaining time
            if [ $((elapsed_time + sleep_duration)) -gt $max_wait ]; then
                sleep_duration=$((max_wait - elapsed_time))
            fi
        fi
    done

    echo_error "{$2} experiment did not start within 5 minutes."
    exit 1
}

# Function to generate the next experiment name
# $1 - experiment name without number suffix (i.e., 'kafka-leader-kill')
# $2 - chaos type of experiment (e.g., PodChaos, NetworkChaos, StressChaos...)
generate_experiment_name() {
    local base_name=$1

    # Get the list of existing Chaos objects with the base name
    local existing_names=$(kubectl get $2 --all-namespaces -o jsonpath="{.items[?(@.metadata.name startsWith ${base_name})].metadata.name}")

    # Find the highest number used so far
    local max_number=-1
    for name in $existing_names; do
        local number=$(echo "$name" | $SED -e "s/^${base_name}-//")
        if [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -gt "$max_number" ]; then
            max_number=$number
        fi
    done

    # Generate the next number
    local next_number=$((max_number + 1))

    # Construct the full experiment name
    echo "${base_name}-${next_number}"
}

# Function to clear all chaos experiments
clear_all_chaos_experiments() {
    echo "Clearing all Chaos experiments..."

    # Deleting PodChaos resources
    kubectl delete podchaos --all --all-namespaces

    # Deleting NetworkChaos resources
    kubectl delete networkchaos --all --all-namespaces

    # Deleting HTTPChaos resources
    kubectl delete httpchaos --all --all-namespaces

    # Deleting StressChaos resources
    kubectl delete stresschaos --all --all-namespaces

    # Deleting DNSChaos resources
    kubectl delete dnschaos --all --all-namespaces

    # Deleting IOChaos resources
    kubectl delete iochaos --all --all-namespaces

    # Add similar commands for other chaos types if needed

    echo_success "All Chaos experiments have been cleared."
}


#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

#####################################################################################################################
########################################  MAIN OF THE PROGRAM ######################################################
#####################################################################################################################
main() {
    local install_flag=false
    local uninstall_flag=false
    local openshift_flag=false
    local pod_chaos_flag=false
    local network_chaos_flag=false
    local experiment_name=""

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
               experiment_name="$1"
               shift
               ;;
           --network-chaos)
               network_chaos_flag=true
               shift
               experiment_name="$1"
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
           --clear-experiments)
               clear_all_chaos_experiments
               exit 0
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
        if [ -z "$experiment_name" ]; then
            list_chaos "pod_chaos"
        elif [ "$experiment_name" == "anubis-kafka-kill-random-pod" ]; then
            local experiment_name=$(generate_experiment_name "anubis-kafka-kill-random-pod" "PodChaos")
            apply_podchaos "${experiment_name}"
            check_chaos_started "${experiment_name}" "PodChaos" "strimzi-kafka"
            verify_kafka_throughput
        # ADD MORE POD CHAOS EXPERIMENTS.. elif [  ]; then
        else
            list_chaos "pod_chaos"
            exit 1
        fi
    fi

    if $network_chaos_flag; then
        if [ -z "$experiment_name" ]; then
            list_chaos "network_chaos"
        elif [ "$experiment_name" == "anubis-kafka-producers-fast-internal-network-delay-all" ]; then
            local experiment_name=$(generate_experiment_name "anubis-kafka-producers-fast-internal-network-delay-all" "NetworkChaos")
            apply_network_chaos_delay_to_internal_producers ${experiment_name}
            check_chaos_started "${experiment_name}" "NetworkChaos" "strimzi-clients"
            verify_kafka_throughput
        # ADD MORE NETWORK CHAOS EXPERIMENTS.. elif [  ]; then
        else
            list_chaos "network_chaos"
            exit 1
        fi
    fi
}

# Call main function with all passed arguments
main "$@"

echo_success "Chaos testing script execution completed."
