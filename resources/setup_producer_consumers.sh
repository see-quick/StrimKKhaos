#!/bin/bash

# Define Kafka topics with their partition and replica counts
declare -A topics_config=(
    ["my-topic-example-1"]="1 3"  # 6 partitions, 3 replicas
   #  ["my-topic-example-2"]="4 3"  # 4 partitions, 3 replicas
   #  ["my-topic-example-3"]="2 3"  # 2 partitions, 3 replicas
)

# Function to create KafkaTopic resources
create_kafka_topic() {
    local topic_name=$1
    local partitions=$2
    local replicas=$3

    cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: $topic_name
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: $partitions
  replicas: $replicas
  config:
    retention.ms: 7200000
    segment.bytes: 1073741824
EOF
}

# Function to create producer or consumer jobs
create_jobs() {
    local job_type=$1
    local topic=$2
    local count=$3
    local start_index=$4  # New parameter for starting index
    local yaml_file=""

    if [ "$job_type" == "producer" ]; then
        yaml_file="producer.yaml"
    elif [ "$job_type" == "consumer" ]; then
        yaml_file="consumer.yaml"
    fi

    for i in $(seq $start_index $(($start_index + $count - 1))); do
        # Create a temporary job file with the current index and topic
        sed "s/{{INDEX}}/$i/" $yaml_file | sed "s/my-topic/$topic/" > kafka-$job_type-$topic-$i.yaml

        # Apply the job
        kubectl apply -f kafka-$job_type-$topic-$i.yaml

        # Optional: Remove the temporary job file
        rm kafka-$job_type-$topic-$i.yaml
    done
}

create_all_kafka_topics() {
    for topic in "${!topics_config[@]}"; do
        IFS=' ' read -r partitions replicas <<< "${topics_config[$topic]}"
        create_kafka_topic $topic $partitions $replicas
    done
}

# Function to create all producer jobs
create_all_producer_jobs() {
    # Create 4 producers for my-topic-example-1
    create_jobs "producer" "my-topic-example-1" 3 1
    # Create 3 producers for my-topic-example-2
    # create_jobs "producer" "my-topic-example-2" 3 5
    # Create 2 producers for my-topic-example-3
    # create_jobs "producer" "my-topic-example-3" 2 8
}

# Function to create all consumer jobs
create_all_consumer_jobs() {
    create_jobs "consumer" "my-topic-example-1" 3 1
    # Create 2 consumers for my-topic-example-2 (4 partitions)
    # create_jobs "consumer" "my-topic-example-2" 2 4
    # Create 1 consumers for my-topic-example-3 (2 partitions)
    # create_jobs "consumer" "my-topic-example-3" 1 6
}

clear_jobs() {
    local jobs_to_delete=$(oc get job | awk -F ' ' '{ print $1 }' | tail -n +2)

    for job_name in $jobs_to_delete; do
        echo "Deleting: $job_name"
        oc delete job $job_name
    done
}

main() {
    case $1 in
        kafka-topics)
            create_all_kafka_topics
            ;;
        producer)
            create_all_producer_jobs
            ;;
        consumer)
            create_all_consumer_jobs
            ;;
        clear_jobs)
            clear_jobs
            ;;
        *)
            echo "Usage: $0 {kafka-topics|producer|consumer}"
            exit 1
            ;;
    esac
}

main "$@"