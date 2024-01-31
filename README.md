# StrimKKhaos

# PoC of StrimKKhaos: Chaos Engineering for Apache Kafka on Kubernetes

## Overview

StrimKKhaos is an initiative to introduce chaos engineering principles into the management of Apache Kafka clusters on Kubernetes, utilizing Chaos Mesh. By simulating disturbances and faults, we aim to validate and improve the resilience of Kafka clusters orchestrated by Strimzi.

## Why Chaos Engineering?

Chaos engineering is critical in a distributed system's lifecycle for testing its ability to endure and recover from unexpected conditions. With StrimKKhaos, we ensure that Kafka clusters are prepared for real-world scenarios, maintaining high availability and consistent performance.

## Choosing the Right Tool: Chaos Mesh

After comparing various chaos engineering frameworks, Chaos Mesh stands out for its active contributions, comprehensive capabilities, and robust support within Kubernetes environments. As a CNCF Incubating project, it is well-positioned for community-driven development and innovative approaches to chaos testing.

## Chaos Testing Scenarios

We have crafted a series of chaos experiments, each designed to challenge different facets of the Kafka-Strimzi ecosystem. These experiments include, but are not limited to:

- Network latency simulation
- Deliberate Kafka broker pod deletion
- Operator functionality under network stress or pod failure
- HTTP chaos (e.g., targeting healthcheck probes, HTTP servers etc.)
- NodeChaos (e.g., restarting the worker node)
- Multi-fault conditions

Each scenario follows a template of defining a steady state, hypothesizing outcomes, designing the experiment, and monitoring and analyzing the results.

## Tech stack

1. **Prometheus**: A powerful time-series database and monitoring solution that works well with Kubernetes. It is commonly used for recording real-time metrics.
2. **Grafana**: For visualizing the data collected by Prometheus. It provides a powerful dashboard to monitor the state of clusters and applications.
3. **Chaos Mesh:** tool tailored for Kubernetes that allows you to easily define and execute chaos experiments.
4. **Loki:** is a highly efficient and scalable log aggregation system from Grafana Labs, optimized for Kubernetes, 
that complements Prometheus and Grafana by enabling cost-effective and seamless indexing and querying of logs using a label-focused approach.

## Getting started

Ensure that these dependencies are installed and properly configured in the environment where the script will run. 
This setup is essential for the script to function correctly.

- **kubectl**: This is the Kubernetes command-line tool, used for running commands against Kubernetes clusters. The script uses kubectl for various operations like checking namespaces, getting pods, applying configurations, etc.
- **helm**: This is the package manager for Kubernetes, used in the script for installing and uninstalling Chaos Mesh.
- **jq**: This is a lightweight and flexible command-line JSON processor. The script uses jq for parsing JSON data, particularly when interacting with the Prometheus API.
- **curl**: This command-line tool is used for transferring data from or to a server. In your script, curl is used to interact with the Prometheus server for metrics scraping.
- **OpenShift CLI** (Optional for OpenShift environments): If the script is being run in an OpenShift environment (as indicated by the openshift_flag), the OpenShift CLI (oc) might be necessary for specific OpenShift-related commands.
- **yq**: A command-line YAML processor that allows you to query and update YAML files. The script requires yq version 4.28.2 for processing YAML files, especially for modifying Chaos experiment specifications.
- **OpenStack CLI**: For NodeChaos experiments in OpenStack environments, the OpenStack command-line interface is necessary to control the underlying OpenStack instances. Ensure that the OpenStack CLI is installed and properly configured with the required credentials and endpoint information.

TODO:
