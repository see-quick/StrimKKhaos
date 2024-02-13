#!/bin/bash

# make script compatible with Linux-based system and also for MacOS
source ./common.sh

# Mandatory environment variables
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}" # Replace 'http://127.0.0.1:9090' with your default Prometheus URL
OPENSTACK_SCRIPT_PATH="${OPENSTACK_SCRIPT_PATH:-./default/openstack_script-tenant-name.sh}"
EXPERIMENT_SLEEP_SECONDS=180

#####################################################################################################################
################################# CHAOS MESH INSTALL/UNINSTALL  #####################################################
#####################################################################################################################

download_helm_repo_if_not_present() {
    # Install 'chaos-mesh' repo in helm if not already present
    local repo_name=$1
    local link=$2

    # Check if the repo is already added
    if ! helm repo list | grep -q "$repo_name"; then
        info "Adding helm repository: $repo_name"
        helm repo add $repo_name $link
    else
        info "Repository $repo_name already exists"
    fi
}

# Function to install Chaos Mesh using Helm and verify that all pods are running
install_chaos_mesh() {
    local release_name=$1
    local namespace=$2
    local cm_version=$3
    local openshift_flag=$4

    download_helm_repo_if_not_present $release_name "https://charts.chaos-mesh.org"

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

    # Wait for chaos-daemon pods to be ready
    wait_for_pods_ready "$namespace" "app.kubernetes.io/component=chaos-daemon"

    # This has to be here until fixed https://github.com/chaos-mesh/chaos-mesh/issues/4313
    # Get all chaos-daemon pod names
    daemon_pods=$(kubectl get pods -n "$namespace" -o custom-columns=:metadata.name --no-headers | grep chaos-daemon)

    # Loop over each daemon pod and execute the modprobe command
    for pod in $daemon_pods; do
      info "Executing modprobe ebtables on pod: $pod"
      kubectl exec -n "$namespace" "$pod" -- modprobe ebtables
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
# $1 - experiment name
# $2 - sut namespace
execute_pod_chaos() {
    local base_pod_chaos_name=$1
    local sut_namespace=$2

    local pod_chaos_yaml="./chaos-manifests/pod_chaos/${base_pod_chaos_name}.yaml"

    if [ ! -f "$pod_chaos_yaml" ]; then
        err "PodChaos experiment named ${base_pod_chaos_name} does not exist."
        list_chaos_experiments "pod_chaos"
        exit 1
    fi

    # Generate a unique experiment name
    local unique_pod_chaos_name=$(generate_unique_name "$base_pod_chaos_name" "PodChaos")

    # Update the .metadata.name and .metadata.namespace fields in the YAML file using yq
    yq e ".metadata.name = \"$unique_pod_chaos_name\"" -i "$pod_chaos_yaml"
    yq e ".metadata.namespace = \"$sut_namespace\"" -i "$pod_chaos_yaml"
    yq e "(.spec.selector.namespaces[0]) = \"$sut_namespace\"" -i "$pod_chaos_yaml"

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
    local sut_namespace=$2

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
    local sut_namespace=$2

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
    yq e ".metadata.namespace = \"$sut_namespace\"" -i "$workflow_yaml"


    # Update namespaces for all selectors within HTTPChaos and StressChaos templates
    yq e "(.spec.templates[] | select(.templateType == \"HTTPChaos\").httpChaos.selector.namespaces[0]) = \"$sut_namespace\"" -i "$workflow_yaml"
    yq e "(.spec.templates[] | select(.templateType == \"StressChaos\").stressChaos.selector.namespaces[0]) = \"$sut_namespace\"" -i "$workflow_yaml"

    info "Executing Workflow Chaos experiment: ${unique_workflow_name}"
    kubectl apply -f "$workflow_yaml"
    info "Workflow Chaos experiment ${unique_workflow_name} has been applied."
}

#####################################################################################################################
############################################### NODE CHAOS ##########################################################
#####################################################################################################################

# Function to execute NodeChaos
execute_node_chaos() {
    local node_name=$1

    # Validate that the node is a Kubernetes worker node
    if ! list_kubernetes_worker_nodes | grep -q "^$node_name$"; then
        err "Node $node_name is not a valid Kubernetes worker node."
        info "Valid Kubernetes worker nodes are:"
        list_kubernetes_worker_nodes
        exit 1
    fi

    # Existing validation code...
    check_node_readiness "$node_name"

    # Check OpenStack token issuance
    check_openstack_token

    info "Performing NodeChaos on node: $node_name"

    # Match the Kubernetes node with the OpenStack machine
    local machine_name="$node_name"

    # Perform soft reboot on the OpenStack machine
    soft_reboot_openstack_machine "$machine_name"
}

# Function to soft reboot an OpenStack machine
soft_reboot_openstack_machine() {
    local machine_name=$1
    info "Soft rebooting OpenStack machine: $machine_name"

    # Execute the soft reboot command
    openstack server reboot --soft "$machine_name"
    if [ $? -ne 0 ]; then
        err "Failed to soft reboot OpenStack machine: $machine_name"
        exit 1
    fi
    info "Soft reboot initiated for machine: $machine_name"
}

# Function to check if a Kubernetes node is READY
check_node_readiness() {
    local node_name=$1
    local node_state=$(kubectl get nodes "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    if [ "$node_state" != "True" ]; then
        err "Node $node_name is not in READY state."
        exit 1
    fi
    info "Node $node_name is in READY state."
}

# Function to monitor node state changes after chaos injection
monitor_node_state_post_chaos() {
    local node_name=$1
    local max_wait_time=600 # Maximum wait time of 10 minutes
    local wait_interval=10 # Check every 10 seconds
    local node_ready
    local stage=1 # Start with stage 1

    info "Monitoring node state changes for $node_name node chaos..."

    while [ $stage -le 2 ]; do
        # Get the current 'Ready' condition status of the node
        node_ready=$(kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

        case $stage in
            1) # Stage 1: Wait for Node to become NotReady
                if [ "$node_ready" != "True" ]; then
                    info "Node $node_name has become NotReady. Proceeding to Stage 2."
                    stage=2 # Proceed to stage 2
                else
                    info "Waiting for Node $node_name to become NotReady..."
                fi
                ;;
            2) # Stage 2: Wait for Node to recover to Ready
                if [ "$node_ready" == "True" ]; then
                    info "Node $node_name has recovered and is Ready."
                    return # Node has recovered, exit the function
                else
                    info "Node $node_name is still NotReady. Waiting for recovery..."
                fi
                ;;
        esac

        sleep $wait_interval
    done

    err "Node $node_name did not recover to Ready state within the maximum wait time."
    exit 1
}

#####################################################################################################################
############################################### PROMETHEUS ##########################################################
#####################################################################################################################

# Function to check Prometheus availability
check_prometheus_availability() {
    local prometheus_url="$PROMETHEUS_URL/api/v1/query?query=up"
    local response=$(curl -s -o /dev/null -w "%{http_code}" $prometheus_url)

    if [ "$response" != "200" ]; then
        err "Prometheus instance at $PROMETHEUS_URL is not available (HTTP status $response). Exiting script."
        exit 1
    else
        info "Prometheus instance at $PROMETHEUS_URL is available."
    fi
}

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
    local namespace="$1"
    local additional_params="pod=~\"$2\",container=\"kafka\""
    local aggregation_function="sum(rate("

    # check that prometheus is available
    check_prometheus_availability

    # Normal average computed based on 1h
    local normal_average=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" | jq -r '.[0].value[1]')
    info "Normal average of messages in the past hour is ${normal_average}"

    sleep $EXPERIMENT_SLEEP_SECONDS

    # Chaos average computed based on 5m interval during the chaos duration
    local chaos_average=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "5m" | jq -r '.[0].value[1]')

    # Perform the comparison to expect a decrease using awk
    local result=$(awk -v ca="$chaos_average" -v na="$normal_average" 'BEGIN {print (ca < na) ? "1" : "0"}')

    if [[ $result -eq 1 ]]; then
        info "Verified expected decrease in Kafka throughput after chaos experiment: chaos average msg/s is ${chaos_average}, which is less than the normal average of ${normal_average}."
    else
        err "Kafka throughput did not decrease as expected: chaos average msg/s is ${chaos_average}, which is not less than the normal average of ${normal_average}."
    fi
}

# Function to verify CPU usage decrease for Kafka pods
verify_kafka_cpu_usage() {
    local expr="container_cpu_usage_seconds_total"
    local namespace="$1"
    local additional_params="pod=~\"$2\",container=\"kafka\""
    local aggregation_function="sum(rate("

    # Fetch average CPU usage based on 1h for each pod
    local average_cpu_usage=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "by (pod)")

    # Decode the JSON output to extract pod names and their average CPU usage
    local pods=($(echo "$average_cpu_usage" | jq -r '.[].metric.pod'))
    local averages=($(echo "$average_cpu_usage" | jq -r '.[].value[1]'))

    sleep $EXPERIMENT_SLEEP_SECONDS

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
    local namespace="$1"
    local additional_params="pod=~\"$2\",container=\"kafka\""
    local aggregation_function="sum(rate("

    # Fetch average memory usage based on 1h for each pod
    local average_memory_usage=$(build_and_execute_query "$expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "by (pod)")

    # Decode the JSON output to extract pod names and their average memory usage
    local pods=($(echo "$average_memory_usage" | jq -r '.[].metric.pod'))
    local averages=($(echo "$average_memory_usage" | jq -r '.[].value[1]'))

    sleep $EXPERIMENT_SLEEP_SECONDS

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
    local namespace="strimzi-bridge"
    local additional_params="topic != \"\""
    local aggregation_function="sum(rate("
    local aggregation_criteria="by (clientId, topic)"

    # Normal average computed based on 1h
    local normal_average=$(build_and_execute_query "$metric_expr" "$namespace" "$additional_params" "$aggregation_function" "1h" "$aggregation_criteria" | jq -r '.[0].value[1]')
    info "Normal average of $metric_name in the past hour is ${normal_average}"

    sleep $EXPERIMENT_SLEEP_SECONDS

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
    echo "  -h, --help                          Show this help message."
    echo "  --install                           Install Chaos Mesh in the specified namespace."
    echo "  --uninstall                         Uninstall Chaos Mesh from the specified namespace."
    echo "  --pod-chaos <experiment_name>       Apply a specific PodChaos experiment."
    echo "  --network-chaos <experiment_name>   Apply a specific NetworkChaos experiment."
    echo "  --workflow-chaos <experiment_name>  Apply a specific Workflow Chaos experiment."
    echo "  --node-chaos <node_name>            Apply NodeChaos on a specific node. Intended for OpenStack environments."
    echo "  --release-name <name>               Specify the release name for Chaos Mesh installation (default: 'chaos-mesh')."
    echo "  --namespace <namespace>             Specify the namespace for Chaos Mesh operations (default: 'chaos-mesh')."
    echo "  --version <version>                 Specify the version of Chaos Mesh to install (default: '2.6.3')."
    echo "  --openshift                         Indicate the script is running in an OpenShift environment."
    echo "  --clear-experiments                 Clear all Chaos experiments across all namespaces."
    echo "  --enable-probes                     Enable probes for checking the state of the system before executing chaos experiments."
    echo "  --install-kubectl                   Install or update the kubectl client to the specified version."
    echo "  --sut-namespace <namespace>         Specify the namespace of the System Under Test (SUT) for chaos experiments."
    echo "  --metrics-selector <selector>       Specify a metrics selector for Prometheus queries during chaos experiments."
    echo ""
    echo "Examples:"
    echo "  $0 --install --release-name my-chaos --namespace my-namespace --version 2.6.3"
    echo "  $0 --pod-chaos anubis-kafka-kill-all-pods --sut-namespace myproject --metrics-selector 'my-cluster-*'"
    echo "  $0 --network-chaos anubis-kafka-producers-fast-internal-network-delay-all --sut-namespace myproject --metrics-selector 'my-cluster-*'"
    echo "  $0 --workflow-chaos my-chaos-workflow --sut-namespace myproject --metrics-selector 'my-cluster-*'"
    echo "  $0 --node-chaos my-node-worker-01 --sut-namespace myproject --metrics-selector 'my-cluster-*' (OpenStack only)"
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

# Waits for all pods in a specified namespace and matching a label selector to be in the 'Ready' state.
#
# $1 - Namespace in which to check for the readiness of pods.
# $2 - Label selector to identify the set of pods to check for readiness.
wait_for_pods_ready() {
    local namespace=$1
    local label_selector=$2
    local retry_count=0
    local max_retries=20
    local sleep_duration=10

    info "Waiting for pods to be ready and running in namespace '$namespace' with label selector '$label_selector'..."

    while [ $retry_count -lt $max_retries ]; do
        local pods_ready=$(kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath='{.items[*].status.containerStatuses[*].ready}')
        local all_pods_ready=true

        # Check readiness for each container in each pod
        for status in $pods_ready; do
            if [[ "$status" != "true" ]]; then
                all_pods_ready=false
                break
            fi
        done

        if $all_pods_ready; then
            info "All pods are ready and running in namespace '$namespace'."
            return
        else
            info "Waiting for pods to be ready and running... (attempt: $((retry_count + 1))/$max_retries)"
            sleep $sleep_duration
            retry_count=$((retry_count + 1))
        fi
    done

    err "Timed out waiting for pods to be ready and running in namespace '$namespace'."
    exit 1
}

# Function to list all Kubernetes worker nodes
list_kubernetes_worker_nodes() {
    info "Listing all Kubernetes worker nodes:"
    kubectl get nodes | grep -v 'master' | awk '{if(NR>1) print $1}' | tr ' ' '\n'
}

# Function to check OpenStack token issuance
check_openstack_token() {
    info "Checking OpenStack token issuance..."
    if ! openstack token issue > /dev/null 2>&1; then
        warn "Initial attempt to issue OpenStack token failed. Attempting to source environment file..."

        # Assuming the path to your environment file is known and fixed

        if [ -f "$OPENSTACK_SCRIPT_PATH" ]; then
            source "$OPENSTACK_SCRIPT_PATH"
            info "Environment file sourced. Trying to issue OpenStack token again..."

            if ! openstack token issue > /dev/null 2>&1; then
                err "Failed to issue OpenStack token after sourcing environment file. Please check your OpenStack credentials and environment."
                exit 1
            else
                info "Successfully issued OpenStack token after sourcing environment file."
            fi
        else
            err "Environment file ($OPENSTACK_SCRIPT_PATH) not found. Cannot source OpenStack credentials."
            exit 1
        fi
    else
        info "Successfully issued OpenStack token."
    fi
}

# Checks readiness of all Kafka pods in a namespace
wait_for_kafka_pods_readiness() {
    local namespace=$1
    local retry_count=0
    local max_retries=20
    local sleep_duration=10
    local all_pods_running=false

    while [ $retry_count -lt $max_retries ]; do
        if kubectl get pods -n "$namespace" -l 'strimzi.io/kind=Kafka' -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
            all_pods_running=true
            break
        fi
        echo "Waiting for Kafka pods to be ready... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_running; then
        echo "All Kafka pods are ready."
    else
        echo "Failed to verify the readiness of all Kafka pods. Please check manually."
        exit 1
    fi
}

# Waits for Strimzi pod set readiness
wait_for_strimzi_podset_readiness() {
    local podset_name=$1
    local namespace=$2
    local retry_count=0
    local max_retries=20
    local sleep_duration=10
    local all_pods_running=false

    while [ $retry_count -lt $max_retries ]; do
        local ready_pods=$(kubectl get strimzipodset "$podset_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}')
        local total_pods=$(kubectl get strimzipodset "$podset_name" -n "$namespace" -o jsonpath='{.status.replicas}')

        if [ "$ready_pods" == "$total_pods" ]; then
            all_pods_running=true
            break
        fi
        echo "Waiting for Strimzi pod set $podset_name to be ready... (attempt: $((retry_count + 1))/$max_retries)"
        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    if $all_pods_running; then
        echo "Strimzi pod set $podset_name is ready."
    else
        echo "Failed to verify the readiness of Strimzi pod set $podset_name. Please check manually."
        exit 1
    fi
}

# Waits for multiple Strimzi pod sets readiness
wait_for_multiple_strimzi_podsets_readiness() {
    local podsets="$1"
    local namespace="$2"
    IFS=',' read -ra PODSETS_ARRAY <<< "$podsets"

    for podset_name in "${PODSETS_ARRAY[@]}"; do
        wait_for_strimzi_podset_readiness "$podset_name" "$namespace"
    done
}

# This function verifies if the Kafka MirrorMaker 2 cluster managed by Strimzi is fully ready and operational after a NodeChaos event.
# It first checks the readiness of all Kafka MirrorMaker 2 pods within a specified namespace and then validates the readiness
# of the StrimziPodSet associated with the Kafka MirrorMaker 2 cluster.
#
# Args:
#   $1 (kmm2_cluster_name) - Name of the Kafka MirrorMaker 2 cluster.
#   $2 (namespace)         - Namespace where Kafka MirrorMaker 2 cluster is deployed.
#
# Returns:
#   Exits with status 0 if all checks pass (i.e., all Kafka MirrorMaker 2 components are ready).
#   Exits with status 1 if any of the readiness checks fail after the maximum number of retries.
#
# Usage example:
#   check_kmm2_readiness "my-mirror-maker-2" "myproject"
#
check_kmm2_readiness() {
    local kmm2_cluster_name=$1
    local kmm2_strimzi_podset_name=$1-mirrormaker2
    local namespace=$2
    local label_selector="strimzi.io/cluster=${kmm2_cluster_name},strimzi.io/kind=KafkaMirrorMaker2"
    local retry_count=0
    local max_retries=20
    local sleep_duration=10

    info "Checking readiness of Kafka MirrorMaker 2 cluster: $kmm2_cluster_name in namespace: $namespace"

    while [ $retry_count -lt $max_retries ]; do
        # Check Kafka MirrorMaker 2 pods readiness
        if kubectl get pods -n "$namespace" -l "$label_selector" -o jsonpath="{.items[*].status.conditions[?(@.type=='Ready')].status}" | grep -q "True"; then
            info "Kafka MirrorMaker 2 cluster $kmm2_cluster_name pods are in READY state."

            # Fetch the total number of pods and number of ready pods from StrimziPodSet status
            local total_pods=$(kubectl get strimzipodset "$kmm2_strimzi_podset_name" -n "$namespace" -o jsonpath="{.status.pods}")
            local ready_pods=$(kubectl get strimzipodset "$kmm2_strimzi_podset_name" -n "$namespace" -o jsonpath="{.status.readyPods}")

            # Compare total pods with ready pods
            if [ "$ready_pods" -eq "$total_pods" ]; then
                info "StrimziPodSet $kmm2_strimzi_podset_name is READY with $ready_pods/$total_pods pods ready."
                return 0
            else
                warn "StrimziPodSet $kmm2_strimzi_podset_name is NOT READY. $ready_pods/$total_pods pods ready. Retrying..."
            fi
        else
            warn "Kafka MirrorMaker 2 cluster $kmm2_cluster_name pods are not READY. Retrying..."
        fi

        sleep $sleep_duration
        retry_count=$((retry_count + 1))
    done

    err "Failed to verify Kafka MirrorMaker 2 cluster $kmm2_cluster_name readiness within the maximum retries."
    exit 1
}

# Checks if the Kafka consumer job has completed successfully.
#
# Args:
#   $1 (namespace) - Namespace where the job is deployed.
#   $2 (job_name)  - Name of the Kafka consumer job.
#
# Returns:
#   Exits with status 0 if the job has completed successfully.
#   Exits with status 1 if the job has failed or not completed.
#
check_kafka_consumer_job_success() {
    local namespace=$1
    local job_name=$2

    if kubectl wait --for=condition=complete job/$job_name --namespace $namespace --timeout=60s; then
        echo "Kafka consumer job $job_name completed successfully."
        return 0
    else
        echo "Kafka consumer job $job_name did not complete successfully."
        return 1
    fi
}

# Checks if the Kafka producer job has completed successfully.
#
# Args:
#   $1 (namespace) - Namespace where the job is deployed.
#   $2 (job_name)  - Name of the Kafka producer job.
#
# Returns:
#   Exits with status 0 if the job has completed successfully.
#   Exits with status 1 if the job has failed or not completed.
#
check_kafka_producer_job_success() {
    local namespace=$1
    local job_name=$2

    if kubectl wait --for=condition=complete job/$job_name --namespace $namespace --timeout=60s; then
        echo "Kafka producer job $job_name completed successfully."
        return 0
    else
        echo "Kafka producer job $job_name did not complete successfully."
        return 1
    fi
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
    local workflow_chaos_flag=false

    # Default values for variables
    local release_name="chaos-mesh"
    local namespace="chaos-mesh"
    local cm_version="2.6.3"
    local kubectl_version="latest"  # Default version, change as needed
    local experiment_name=""
    local chaos_type=""
    local sut_namespace=""
    local metrics_selector=""
    local strimzi_pod_sets=""

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
              chaos_type="pod-chaos"
              shift
              experiment_name="$1"
              shift
              ;;
          --network-chaos)
              network_chaos_flag=true
              chaos_type="network-chaos"
              shift
              experiment_name="$1"
              shift
              ;;
          --workflow-chaos)
              workflow_chaos_flag=true
              chaos_type="workflow-chaos"
              shift
              experiment_name="$1"
              shift
              ;;
          --node-chaos)
              node_chaos_flag=true
              chaos_type="node-chaos"
              shift
              node_name="$1"
              shift
              shift
              ;;
           --sut-namespace)
               if [[ -n $chaos_type && $chaos_type != "node-chaos" ]]; then
                   sut_namespace="$2"
               else
                   err "The --sut-namespace option is not applicable to $chaos_type."
                   exit 1
               fi
               shift
               shift
               ;;
           --metrics-selector)
               if [[ -n $chaos_type && $chaos_type != "node-chaos" ]]; then
                   metrics_selector="$2"
               else
                   err "The --metrics-selector option is not applicable to $chaos_type."
                   exit 1
               fi
               shift
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
           --strimzi-pod-sets)
               strimzi_pod_sets="$2"
               shift # past argument
               shift # past value
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
        exit 0
    fi

    if $uninstall_flag; then
        uninstall_chaos_mesh "$release_name" "$namespace"
        exit 0
    fi

    check_kubectl_installed
    check_chaos_mesh_installed

    if $enable_probes_flag; then
        check_all_machine_pools_updating
    fi

    if $install_kubectl_flag; then
        install_kubectl "$kubectl_version" "$install_kubectl_flag"
    fi

    # Additional checks after processing all options
    if [[ $chaos_type == "pod-chaos" || $chaos_type == "network-chaos" || $chaos_type == "workflow-chaos" ]]; then
        if [[ -z "$sut_namespace" ]]; then
            err "You must specify a SUT namespace with --sut-namespace for $chaos_type."
            exit 1
        fi
        if [[ -z "$metrics_selector" ]]; then
            err "You must specify a metrics selector with --metrics-selector for $chaos_type."
            exit 1
        fi
    fi

    if $pod_chaos_flag; then
        execute_pod_chaos "$experiment_name" "$sut_namespace" "$metrics_selector"

        verify_kafka_throughput "$sut_namespace" "$metrics_selector"

        # wait for Kafka pods readiness
        wait_for_kafka_pods_readiness "$sut_namespace"

        # If StrimziPodSets are provided, we also check readiness of them
        if [[ -n "$strimzi_pod_sets" ]]; then
            wait_for_multiple_strimzi_podsets_readiness "$strimzi_pod_sets" "$sut_namespace"
        fi
    elif $network_chaos_flag; then
        execute_network_chaos "$experiment_name" "$sut_namespace" "$metrics_selector"

        verify_kafka_throughput "$sut_namespace" "$metrics_selector"
    elif $workflow_chaos_flag; then
        execute_workflow_chaos "$experiment_name" "$sut_namespace" "$metrics_selector"

        # run verification procedures in parallel
        verify_kafka_throughput "$sut_namespace" "$metrics_selector" &
        verify_kafka_memory_usage "$sut_namespace" "$metrics_selector" &
        verify_kafka_cpu_usage "$sut_namespace" "$metrics_selector" &

        # TODO: check for target cluster metrics

        verify_kafka_bridge_metric "strimzi_bridge_kafka_producer_byte_total" "KafkaBridge bytes produced" &
        verify_kafka_bridge_metric "strimzi_bridge_kafka_producer_record_send_total" "KafkaBridge records sent" &

        info "Waiting for all background jobs to finish"
        wait
        # TODO: add post checks that after successful Chaos experiment messages increased and overall load too
    elif $node_chaos_flag; then
        # producer and consumer spawn
        kubectl apply -f ./resources/topic/kafka-topic.yaml
        kubectl apply -f ./resources/clients/producer-node-chaos.yaml
        kubectl apply -f ./resources/clients/consumer-node-chaos.yaml

        execute_node_chaos "$node_name"

        monitor_node_state_post_chaos "$node_name"

        # TODO: parametrize this
        check_kafka_readiness "my-cluster" "myproject"
        check_kafka_readiness "my-target-cluster" "myproject"
        check_kmm2_readiness "my-mirror-maker-2" "myproject"

        check_kafka_producer_job_success "myproject" "kafka-producer-client"
        check_kafka_consumer_job_success "myproject" "kafka-consumer-client"

        # TODO: always delete
        kubectl delete -f ./resources/topic/kafka-topic.yaml
        kubectl delete -f ./resources/clients/producer-node-chaos.yaml
        kubectl delete -f ./resources/clients/consumer-node-chaos.yaml
    fi
}

# Call main function with all passed arguments
main "$@"

info "Chaos testing script execution completed."
