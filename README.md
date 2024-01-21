# StrimKKhaos

# StrimKKhaos: Chaos Engineering for Apache Kafka on Kubernetes

## Overview

StrimKKhaos is an initiative to introduce chaos engineering principles into the management of Apache Kafka clusters on Kubernetes, utilizing Chaos Mesh. By simulating disturbances and faults, we aim to validate and improve the resilience of Kafka clusters orchestrated by Strimzi.

## Why Chaos Engineering?

Chaos engineering is critical in a distributed system's lifecycle for testing its ability to endure and recover from unexpected conditions. With StrimKKhaos, we ensure that Kafka clusters are prepared for real-world scenarios, maintaining high availability and consistent performance.

## Choosing the Right Tool: Chaos Mesh

After comparing various chaos engineering frameworks, Chaos Mesh stands out for its active contributions, comprehensive capabilities, and robust support within Kubernetes environments. As a CNCF Sandbox project, it is well-positioned for community-driven development and innovative approaches to chaos testing.

## Chaos Testing Scenarios

We have crafted a series of chaos experiments, each designed to challenge different facets of the Kafka-Strimzi ecosystem. These experiments include, but are not limited to:

- Network latency simulation
- Deliberate Kafka broker pod deletion
- Operator functionality under network stress or pod failure
- HTTP chaos (e.g., targeting healthcheck probes, HTTP servers etc.)
- Multi-fault conditions

Each scenario follows a template of defining a steady state, hypothesizing outcomes, designing the experiment, and monitoring and analyzing the results.

## Tech stack

1. **Prometheus**: A powerful time-series database and monitoring solution that works well with Kubernetes. It is commonly used for recording real-time metrics.
2. **Grafana**: For visualizing the data collected by Prometheus. It provides a powerful dashboard to monitor the state of clusters and applications.
3. **Chaos Mesh:** tool tailored for Kubernetes that allows you to easily define and execute chaos experiments.
4. **Loki:** is a highly efficient and scalable log aggregation system from Grafana Labs, optimized for Kubernetes, 
that complements Prometheus and Grafana by enabling cost-effective and seamless indexing and querying of logs using a label-focused approach.

## Getting started

TODO: