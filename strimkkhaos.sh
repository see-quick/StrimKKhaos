#!/bin/bash

# make script compatible with Linux-based system and also for MacOS
source ./common.sh

# Mandatory environment variables
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}" # Replace 'http://default-prometheus-url' with your default Prometheus URL

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
        warn "Namespace $namespace does not exist. Creating it..."
        kubectl create namespace "$namespace"
        info "Namespace $namespace created."
    fi

    info "Installing Chaos Mesh version $cm_version in namespace $namespace with release name $release_name"
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
        info "Waiting for Chaos Mesh pods to be running... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_running; then
        info "Chaos Mesh installed successfully and all pods are running."
    else
        err "Failed to verify the startup of all Chaos Mesh pods. Please check manually."
        exit 1
    fi

    if [ "$openshift_flag" = true ]; then
        if ! oc get scc privileged -o jsonpath='{.users[]}' | $GREP -q "system:serviceaccount:$namespace:chaos-daemon"; then
            oc adm policy add-scc-to-user privileged system:serviceaccount:$namespace:chaos-daemon
            info "Added 'privileged' SCC to 'chaos-daemon' service account."
        else
            warn "'chaos-daemon' service account already has 'privileged' SCC. Skipping this step."
        fi
    fi

    # This has to be here until fixed https://github.com/chaos-mesh/chaos-mesh/issues/4313
    # Get all chaos-daemon pod names
    daemon_pods=$(kubectl get pods -n chaos-mesh -o custom-columns=:metadata.name --no-headers | grep chaos-daemon)

    # Loop over each daemon pod and execute the modprobe command
    for pod in $daemon_pods; do
      info "Executing modprobe ebtables on pod: $pod"
      kubectl exec -n chaos-mesh "$pod" -- modprobe ebtables
    done

    info "All daemon pods have been processed."
}

# Function to uninstall Chaos Mesh using Helm and verify that all pods are deleted
uninstall_chaos_mesh() {
    local release_name=$1
    local namespace=$2

    info "Uninstalling Chaos Mesh with release name $release_name from namespace $namespace"
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
        info "Waiting for Chaos Mesh pods to be deleted... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_deleted; then
        info "Chaos Mesh uninstalled successfully and all pods are deleted."
    else
        err "Failed to verify the deletion of all Chaos Mesh pods. Please check manually."
        exit 1
    fi
}

#####################################################################################################################
################################################ POD CHAOS ##########################################################
#####################################################################################################################

# Function to execute a PodChaos experiment with a unique name
execute_pod_chaos() {
    local base_pod_chaos_name=$1
    local pod_chaos_yaml="./chaos-manifests/pod_chaos/${base_pod_chaos_name}.yaml"

    if [ ! -f "$pod_chaos_yaml" ]; then
        err "PodChaos experiment named ${base_pod_chaos_name} does not exist."
        list_chaos_experiments "pod_chaos"
        exit 1
    fi

    # Generate a unique experiment name
    local unique_pod_chaos_name=$(generate_unique_name "$base_pod_chaos_name" "PodChaos")

    # Update the .metadata.name field in the YAML file using yq
    yq e ".metadata.name = \"$unique_pod_chaos_name\"" -i "$pod_chaos_yaml"

    info "Executing PodChaos experiment: ${unique_pod_chaos_name}"
    kubectl apply -f "$pod_chaos_yaml"
    info "PodChaos experiment ${unique_pod_chaos_name} has been applied."
}

round() {
    echo "$1" | awk '{printf "%.2f", $1}'
}

#####################################################################################################################
############################################## NETWORK CHAOS ########################################################
#####################################################################################################################

################################### PRODUCER FAST INTERNAL NETWORK DELAY ############################################

execute_network_chaos() {
    local base_network_chaos_name=$1
    local network_chaos_yaml="./chaos-manifests/network_chaos/${base_network_chaos_name}.yaml"

    if [ ! -f "$network_chaos_yaml" ]; then
        err "Network chaos experiment named ${base_network_chaos_name} does not exist."
        list_chaos_experiments "network_chaos"
        exit 1
    fi

    # Generate a unique workflow name
    local unique_network_chaos_name=$(generate_unique_name "$base_network_chaos_name" "NetworkChaos")

    # Update only the .metadata.name field in the YAML file using yq
    yq e ".metadata.name = \"$unique_network_chaos_name\"" -i "$network_chaos_yaml"

    info "Executing NetworkChaos experiment: ${unique_network_chaos_name}"
    kubectl apply -f "$network_chaos_yaml"
    info "NetworkChaos Chaos experiment ${unique_network_chaos_name} has been applied."
}

#####################################################################################################################
########################################### WORKFLOW CHAOS ##########################################################
#####################################################################################################################

# Function to execute a complex workflow chaos experiment with unique name incrementation
# $1 - base name of the workflow experiment
execute_workflow_chaos() {
    local base_workflow_name=$1
    local workflow_yaml="./chaos-manifests/workflow_chaos/${base_workflow_name}.yaml"

    if [ ! -f "$workflow_yaml" ]; then
        err "Workflow chaos experiment named ${base_workflow_name} does not exist."
        list_chaos_experiments "workflow_chaos"
        exit 1
    fi

    # Generate a unique workflow name
    local unique_workflow_name=$(generate_unique_name "$base_workflow_name" "Workflow")

    # Update only the .metadata.name field in the YAML file using yq
    yq e ".metadata.name = \"$unique_workflow_name\"" -i "$workflow_yaml"

    info "Executing Workflow Chaos experiment: ${unique_workflow_name}"
    kubectl apply -f "$workflow_yaml"
    info "Workflow Chaos experiment ${unique_workflow_name} has been applied."
}

#####################################################################################################################
############################################### PROMETHEUS ##########################################################
#####################################################################################################################

# Function to scrape Prometheus metrics at regular intervals
scrape_metrics_during_chaos() {
    local expr=$1
    local namespace=$2
    local additional_params=$3
    local aggregation_function=$4
    local time_range=$5
    local interval=$6
    local duration=$7
    local aggregation_criteria=${8:-""} # Defaults to empty if not provided

    local end_time=$((SECONDS + duration))
    local total=0
    local count=0

    while [ $SECONDS -lt $end_time ]; do
        local result=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "$time_range" "$aggregation_criteria" | jq -r '.[0].value[1]')
        if [[ $result != null ]]; then
            total=$(echo "$total $result" | awk '{print $1 + $2}')
            count=$((count + 1))
        fi
        sleep $interval
    done

    if [ $count -gt 0 ]; then
        local average=$(echo "$total $count" | awk '{print $1 / $2}')
        local round_average_two_decimals=$(round $average)
        echo "$round_average_two_decimals"
    else
        err "No metrics scraped."
        exit 1
    fi
}

# Function to build and execute a Prometheus query
# $1 - Query expression
# $2 - Namespace
# $3 - Additional parameters (e.g., pod regex, container name)
# $4 - Aggregation function (e.g., sum, rate)
# $5 - Time range
# $6 - Optional aggregation criteria (e.g., by (pod))
build_and_execute_query() {
    local expr=$1
    local namespace=$2
    local additional_params=$3
    local aggregation_function=$4
    local time_range=$5
    local aggregation_criteria=${6:-""} # Defaults to empty if not provided

    local open_parentheses_count=$(grep -o "(" <<< "$aggregation_function" | wc -l)
    local close_parentheses=")"
    for ((i=1; i<open_parentheses_count; i++)); do
        close_parentheses+=")"
    done

    # Construct the query expression
    local query_expr="${aggregation_function}${expr}{namespace=\"${namespace}\",${additional_params}}[${time_range}]${close_parentheses} ${aggregation_criteria}"

    # Execute the query
    local result=$(curl -s -G --data-urlencode "query=${query_expr}" "${PROMETHEUS_URL}/api/v1/query" | jq -r '.data.result')

    echo "${result}"
}

# Function to verify decrease in Kafka throughput
verify_kafka_throughput() {
    local expr="kafka_server_brokertopicmetrics_messagesin_total"
    local namespace="strimzi-kafka"
    local additional_params="pod=~\"anubis-.*\",container=\"kafka\""
    local aggregation_function="sum(irate("

    # Normal average computed based on 1h
    local normal_average=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" | jq -r '.[0].value[1]')
    info "Normal average of messages in the past hour is ${normal_average}"

    sleep 5

    # Chaos average computed based on 5m interval during the chaos duration
    local chaos_average=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "5m" | jq -r '.[0].value[1]')

    # Perform the comparison using awk
    result=$(echo "$chaos_average $normal_average" | awk '{print ($1 < $2) ? "1" : "0"}')

    if [[ $result -eq 1 ]]; then
        info "Verified expected decrease in Kafka throughput after chaos experiment: chaos average msg/s is ${chaos_average} which is lower than normal average i.e., ${normal_average}"
    else
        err "Kafka throughput did not decrease as expected: chaos average msg/s is ${chaos_average} which is greater than normal average i.e., ${normal_average}"
    fi
}

# Function to verify CPU usage decrease for Kafka pods
verify_kafka_cpu_usage() {
    local expr="container_cpu_usage_seconds_total"
    local namespace="myproject"
    local additional_params="pod=~\"my-cluster-.*\",container=\"kafka\""
    local aggregation_function="sum(rate("

    # Fetch average CPU usage based on 1h for each pod
    local average_cpu_usage=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "by (pod)")

    # Decode the JSON output to extract pod names and their average CPU usage
    local pods=($(echo "$average_cpu_usage" | jq -r '.[].metric.pod'))
    local averages=($(echo "$average_cpu_usage" | jq -r '.[].value[1]'))

    sleep 300

    # Initialize total recent CPU usage and total average CPU usage
    local total_recent=0
    local total_average=0

    # Iterate over each pod and compare recent CPU usage with the average
    local i=0
    for pod in "${pods[@]}"; do
        local pod_name=${pods[$i]}
        local average=${averages[$i]}

        # Fetch CPU usage during the last 5 minutes for the specific pod
        local recent_cpu_usage=$(build_and_execute_query "$expr" "$namespace" "pod=\"${pod_name}\",container=\"kafka\"" "$aggregation_function" "5m")

        # Extract the recent CPU usage value
        local recent=$(echo "$recent_cpu_usage" | jq -r '.[0].value[1]')

        # Aggregate total recent and average CPU usage
        total_recent=$(awk "BEGIN {print $total_recent + $recent}")
        total_average=$(awk "BEGIN {print $total_average + $average}")

        # Display CPU usage for each pod
        if [[ $(awk "BEGIN {print ($recent < $average) ? 1 : 0}") -eq 1 ]]; then
            info "CPU usage for pod $pod_name in the last 5 minutes is lower than the average: $recent < $average (average)"
        else
            err "CPU usage for pod $pod_name is normal: $recent >= $average (average)"
        fi

        i=$((i + 1))
    done

    # Perform the comparison using awk for total CPU usage
    local result=$(awk "BEGIN {print ($total_recent < $total_average) ? 1 : 0}")

    if [[ $result -eq 1 ]]; then
        info "Total CPU usage for all Kafka pods in the last 5 minutes is lower than the average: $total_recent < $total_average (average)"
    else
        err "Total CPU usage for all Kafka pods is normal: $total_recent >= $total_average (average)"
    fi
}

# Function to verify memory usage decrease for Kafka pods
verify_kafka_memory_usage() {
    local expr="container_memory_usage_bytes"
    local namespace="myproject"
    local additional_params="pod=~\"my-cluster-.*\",container=\"kafka\""
    local aggregation_function="sum(rate("

    # Fetch average memory usage based on 1h for each pod
    local average_memory_usage=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "by (pod)")

    # Decode the JSON output to extract pod names and their average memory usage
    local pods=($(echo "$average_memory_usage" | jq -r '.[].metric.pod'))
    local averages=($(echo "$average_memory_usage" | jq -r '.[].value[1]'))

    sleep 300

    # Initialize total recent memory usage and total average memory usage
    local total_recent=0
    local total_average=0

    # Iterate over each pod and compare recent memory usage with the average
    local i=0
    for pod in "${pods[@]}"; do
        local pod_name=${pods[$i]}
        local average=$(awk "BEGIN {print ${averages[$i]}}")

        # Fetch memory usage during the last 5 minutes for the specific pod
        local recent_memory_usage=$(build_and_execute_query "$expr" "$namespace" "pod=\"${pod_name}\",container=\"kafka\"" "$aggregation_function" "5m")

        # Extract the recent memory usage value and convert
        local recent=$(echo "$recent_memory_usage" | jq -r '.[0].value[1]')

        # Aggregate total recent and average memory usage
        total_recent=$(awk "BEGIN {print $total_recent + $recent}")
        total_average=$(awk "BEGIN {print $total_average + $average}")

        # Display memory usage for each pod
        if [[ $(awk "BEGIN {print ($recent < $average) ? 1 : 0}") -eq 1 ]]; then
            warn "Memory usage for pod $pod_name in the last 5 minutes is lower than the average: ${recent} < ${average}"
        else
            info "Memory usage for pod $pod_name is normal: ${recent} >= ${average}"
        fi
        i=$((i + 1))
    done

    # Convert total values to MB for the final comparison
    total_recent=$(awk "BEGIN {print $total_recent}")
    total_average=$(awk "BEGIN {print $total_average}")

    # Perform the comparison using awk for total memory usage
    local result=$(awk "BEGIN {print ($total_recent < $total_average) ? 1 : 0}")

    if [[ $result -eq 1 ]]; then
        info "Total memory usage for all Kafka pods in the last 5 minutes is lower than the average: ${total_recent} < ${total_average}"
    else
        warn "Total memory usage for all Kafka pods is normal: ${total_recent} >= ${total_average}"
    fi
}

# Generic function to verify KafkaBridge metrics
verify_kafka_bridge_metric() {
    local metric_expr=$1
    local metric_name=$2
    local namespace="myproject"
    local additional_params="topic != \"\""
    local aggregation_function="sum(rate("
    local aggregation_criteria="by (clientId, topic)"

    # Normal average computed based on 1h
    local normal_average=$(build_and_execute_query "$metric_expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "$aggregation_criteria" | jq -r '.[0].value[1]')
    info "Normal average of $metric_name in the past hour is ${normal_average}"

    sleep 300

    # Chaos average computed based on 5m interval during the chaos duration
    local chaos_average=$(build_and_execute_query "$metric_expr" "$namespace" "$additional_params" "$aggregation_function" "5m" "$aggregation_criteria" | jq -r '.[0].value[1]')

    # Perform the comparison using awk
    local result=$(echo "$chaos_average $normal_average" | awk '{print ($1 < $2) ? "1" : "0"}')

    if [[ $result -eq 1 ]]; then
        info "Verified expected decrease in ${metric_name} after chaos experiment: chaos average is ${chaos_average}[b] which is lower than normal average i.e., ${normal_average}[b]"
    else
        err "${metric_name} did not decrease as expected: chaos average is ${chaos_average}[b] which is greater than normal average i.e., ${normal_average}[b]"
    fi
}

#####################################################################################################################
########################################### AUXILIARY METHODS #######################################################
#####################################################################################################################

# Generic function to list all Chaos experiments from YAML files
# $1 - type of experiment (e.g., workflow_chaos, pod_chaos, network_chaos)
list_chaos_experiments() {
    local experiment_type=$1
    info "Supported $experiment_type experiments: "

    local directory="./chaos-manifests/$experiment_type"
    local files=("$directory"/*.yaml)

    if [ -d "$directory" ] && [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            if [ -f "$file" ]; then
                local experiment_name=$(basename "$file" .yaml)
                info "- $experiment_name"
            fi
        done
    else
        err "No $experiment_type YAML files found in $directory."
    fi
}

# Function to display usage information
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help                          Show this help message"
    echo "  --install                           Install Chaos Mesh"
    echo "  --uninstall                         Uninstall Chaos Mesh"
    echo "  --pod-chaos <experiment_name>       Apply a specific PodChaos experiment"
    echo "  --network-chaos <experiment_name>   Apply a specific NetworkChaos experiment"
    echo "  --workflow-chaos <experiment_name>  Apply a specific Workflow Chaos experiment"
    echo "  --release-name <name>               Specify the release name for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --namespace <namespace>             Specify the namespace for Chaos Mesh (default: 'chaos-mesh')"
    echo "  --version <version>                 Specify the version of Chaos Mesh (default: '2.6.3')"
    echo "  --openshift                         Indicate the script is running in an OpenShift environment"
    echo "  --clear-experiments                 Clear all Chaos experiments"
    echo "  --enable-probes                     Enable probes for checking the state of the system"
    echo "  --install-kubectl                   Install or update kubectl client"
    echo ""
    echo "Example:"
    echo "  $0 --install --release-name my-chaos --namespace my-namespace --version 2.6.3"
    echo "  $0 --pod-chaos anubis-kafka-kill-all-pods"
    echo "  $0 --network-chaos anubis-kafka-producers-fast-internal-network-delay-all"
    echo "  $0 --workflow-chaos my-chaos-workflow"
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
            info "{$2} experiment has started."
            return
        else
            info "Waiting for {$2} experiment to start... Next check in $sleep_duration seconds."
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

    err "{$2} experiment did not start within 5 minutes."
    exit 1
}

# Function to generate the next unique name for a given resource type
# $1 - base name of the resource (i.e., 'kafka-leader-kill' for Chaos or 'parallel-http-bridge' for Workflow)
# $2 - resource type (e.g., PodChaos, NetworkChaos, StressChaos, Workflow...)
generate_unique_name() {
    local base_name=$1
    local resource_type=$2
    local max_suffix=0
    local existing_names=$(kubectl get "$resource_type" --all-namespaces -o jsonpath="{.items[?(@.metadata.name startsWith ${base_name})].metadata.name}")

    for name in $existing_names; do
        local suffix=$(echo "$name" | sed -e "s/^${base_name}-//")
        if [[ "$suffix" =~ ^[0-9]+$ ]] && [ "$suffix" -gt "$max_suffix" ]; then
            max_suffix=$suffix
        fi
    done

    local next_suffix=$((max_suffix + 1))
    echo "${base_name}-${next_suffix}"
}

# Function to clear all chaos experiments
clear_all_chaos_experiments() {
    info "Clearing all Chaos experiments..."

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

    # Deleting Workflow resources
    kubectl delete workflow --all --all-namespaces

    info "All Chaos experiments have been cleared."
}

# Function to check if all machine pools are updating
check_all_machine_pools_updating() {
    # Get all machine pool names
    local pools=$(kubectl get machineconfigpool -o jsonpath='{.items[*].metadata.name}')

    for pool in $pools; do
        info "Checking MachineConfigPool:${pool}"
        local status=$(kubectl get machineconfigpool "$pool" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')

        if [ "$status" == "True" ]; then
            warn "MachineConfigPool ${pool} is updating."
            err "Execution of the current chaos experiment would be terminated because we want to have steady state of the application!"
        else
            info "MachineConfigPool ${pool} is not updating."
            info "Continue with execution of the chaos experiment."
        fi
    done
}

# is_less_version_than
#
# Compares two version strings to determine if the first version is less than the second.
#
# @param $1 First version string to compare.
# @param $2 Second version string to compare.
# @return Returns 0 (true) if $1 is less than $2, 1 (false) otherwise.
#
# Usage example:
# if is_less_version_than "1.2.3" "1.2.4"; then
#     echo "1.2.3 is less than 1.2.4"
# fi
is_less_version_than() {
    compare_versions $1 $2
    if [ $? == 2 ];  then
        return 0
    fi

    return 1
}

# compare_versions
#
# Compares two version strings.
#
# @param $1 First version string.
# @param $2 Second version string.
# @return Returns 0 if $1 equals $2, 1 if $1 is greater, and 2 if $1 is less.
#
# Usage example:
# compare_versions "1.2.3" "1.2.4"
# result=$?
compare_versions () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1 ver2
    read -ra ver1 <<< "$1"
    read -ra ver2 <<< "$2"
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

# install_kubectl
#
# Installs the kubectl client at a specified version.
#
# @param $1 Version of kubectl to be installed.
# @return Installs or updates kubectl to the specified version.
#
# Usage example:
# install_kubectl "v1.20.0"
install_kubectl() {
    local kubectl_version=$1

    info "Installing KUBECTL client with version ${kubectl_version}"

    err_msg=$(kubectl version --client=true --output=yaml 2>&1 1>/dev/null)
    if [ "$err_msg" == "" ]; then
        current_version=$(kubectl version --client=true --output=yaml | grep gitVersion | sed 's/.*gitVersion: v\([0-9.]*\).*/\1/g')
        target_version=$(echo "${kubectl_version}" | sed s/"${current_version}"//g)
        if is_less_version_than "${current_version}" "${target_version}"; then
            warn "Chaos Mesh requires kubectl version ${target_version} or higher!"
        else
            info "kubectl Version ${current_version} has been installed"
        fi
    else
        err "${err_msg}"
    fi

    local KUBECTL_BIN="${HOME}/local/bin/kubectl"
    local target_os=$(lowercase "$(uname)")

    curl -Lo /tmp/kubectl https://storage.googleapis.com/kubernetes-release/release/${kubectl_version}/bin/${target_os}/amd64/kubectl
    chmod +x /tmp/kubectl
    mv /tmp/kubectl "${KUBECTL_BIN}"
}

# Function to check if Chaos Mesh is installed
check_chaos_mesh_installed() {
    if ! kubectl get crd podchaos.chaos-mesh.org &> /dev/null; then
        err "Chaos Mesh is not installed. Please install it before running this script."
        exit 1
    fi

    # Check if Chaos Mesh pods are running
    if ! kubectl get pods -n "$namespace" | grep -q 'Running'; then
        err "Chaos Mesh pods are not running in the '$namespace' namespace. Please ensure Chaos Mesh is operational before running this script."
        exit 1
    fi

    info "Chaos Mesh is installed and operational."
}

# Function to check if kubectl is installed
check_kubectl_installed() {
    if ! command -v kubectl &> /dev/null; then
        err "kubectl is not installed. Please install it before running this script."
        exit 1
    fi
    info "kubectl is installed."
}

#####################################################################################################################
########################################  MAIN OF THE PROGRAM ######################################################
#####################################################################################################################
main() {
    local install_flag=false
    local uninstall_flag=false
    local openshift_flag=false
    local pod_chaos_flag=false
    local network_chaos_flag=false
    local enable_probes_flag=false
    local install_kubectl_flag=false
    local experiment_name=""
    local workflow_chaos_flag=false

    # Default values for variables
    local release_name="chaos-mesh"
    local namespace="chaos-mesh"
    local cm_version="2.6.3"
    local kubectl_version="latest"  # Default version, change as needed

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
           --enable-probes)
               enable_probes_flag=true
               shift
               ;;
           --install-kubectl)
               install_kubectl_flag=true
               shift
               ;;
           --workflow-chaos)
               workflow_chaos_flag=true
               shift
               experiment_name="$1"
               shift
               ;;
           *)
               err "Unknown option $key"
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

    check_kubectl_installed
    check_chaos_mesh_installed

    if $enable_probes_flag; then
        check_all_machine_pools_updating
    fi

    if $install_kubectl_flag; then
        install_kubectl "$kubectl_version" "$install_kubectl_flag"
    fi

    if $pod_chaos_flag; then
        execute_pod_chaos "$experiment_name"

        verify_kafka_throughput
    fi

    if $network_chaos_flag; then
        execute_network_chaos "$experiment_name"

        verify_kafka_throughput
    fi

    if $workflow_chaos_flag; then
        execute_workflow_chaos "$experiment_name"

        # run verification procedures in parallel
        verify_kafka_throughput &
        verify_kafka_memory_usage &
        verify_kafka_cpu_usage &

        # TODO: check for target cluster metrics

        verify_kafka_bridge_metric "strimzi_bridge_kafka_producer_byte_total" "KafkaBridge bytes produced" &
        verify_kafka_bridge_metric "strimzi_bridge_kafka_producer_record_send_total" "KafkaBridge records sent" &

        info "Waiting for all background jobs to finish"
        wait

        # TODO: add post checks that after successful Chaos experiment messages increased and overall load too
    fi
}

# Call main function with all passed arguments
main "$@"

info "Chaos testing script execution completed."
