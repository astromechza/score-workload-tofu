# score-workload-tofu

This is a Terraform / OpenTofu compatible module to be used to provision `score-workload` resources ontop of Kubernetes for the Humanitec Orchestrator.

## Requirements

1. There must be a module provider setup for `kubernetes` (`hashicorp/kubernetes`).

## Installation

Install this with the `canyon` CLI, you should replace the `CHANGEME` in the provider mapping with your real provider type and alias for Kubernetes; and replace the CHANGEME in module_inputs with the real target namespace.

```shell
canyon create module-definition \
    --set=resource_type=score-workload \
    --set=module_source=git::https://github.com/astromechza/score-workload-tofu \
    --set=provider_mapping='{"kubernetes": "CHANGEME"}' \
    --set=module_inputs='{"namespace": "CHANGEME"}'
```

**Dynamic namespaces**

Instead of a hardcoded destination namespace, you can use the resource graph to provision a namespace.

1. Ensure there is a resource type for the namespace (eg: `k8s-namespace`) and that there is a definition and rule set up for it in the target environments.
2. Add a dependency to the create module definition request:

    ```
    --set=dependencies='{"ns": {"type": "k8s-namespace"}}'
    ```

3. In the module inputs replace this with the placeholder:

    ```
    --set=module_inputs='{"namespace": "${ resources.ns.outputs.name }"}'
    ```
