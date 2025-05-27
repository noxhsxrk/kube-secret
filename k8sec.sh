#!/bin/bash

if ! command -v kubectl &>/dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

if ! kubectl get pods &>/dev/null; then
    echo "Error: Not connected to a Kubernetes cluster"
    exit 1
fi

CONFIG_DIR="$HOME/.k8sec"
EXCLUDE_FILE="$CONFIG_DIR/exclude-namespaces.txt"
SERVICES_JSON="$CONFIG_DIR/services.json"

mkdir -p "$CONFIG_DIR"

usage() {
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  <service-name> [env-type] [config-type]  - Fetch secrets for a service"
    echo "  list-services                           - Generate services.json with all namespaces and services"
    echo "  config                                  - Edit the exclude namespaces configuration file"
    echo ""
    echo "Arguments for fetch command:"
    echo "  service-name: Name of the service to fetch secrets from"
    echo "  env-type: Optional - Environment to use (dev/qa/prod)"
    echo "  config-type: Optional - Specify whether to get config.json or .env (defaults to auto-detect)"
    exit 1
}

config() {
    if [ ! -f "$EXCLUDE_FILE" ]; then
        echo "# List of namespaces to exclude from the services list" >"$EXCLUDE_FILE"
        echo "# Use asterisk (*) for prefix matching (e.g., 'namespace-*' excludes all namespaces starting with 'namespace-')" >>"$EXCLUDE_FILE"
        echo "# Example:" >>"$EXCLUDE_FILE"
        echo "# kube-system" >>"$EXCLUDE_FILE"
        echo "# kube-public" >>"$EXCLUDE_FILE"
        echo "# namespace-*" >>"$EXCLUDE_FILE"
        echo "Created exclude namespaces file at $EXCLUDE_FILE"
    fi

    if [ -n "$EDITOR" ]; then
        EDIT_CMD="$EDITOR"
    elif command -v code &>/dev/null; then
        EDIT_CMD="code --wait"
    elif command -v nano &>/dev/null; then
        EDIT_CMD="nano"
    elif command -v vim &>/dev/null; then
        EDIT_CMD="vim"
    elif command -v vi &>/dev/null; then
        EDIT_CMD="vi"
    else
        echo "No suitable editor found. Set the EDITOR environment variable or install VS Code, nano, vim, or vi."
        echo "Configuration file is located at: $EXCLUDE_FILE"
        exit 1
    fi

    echo "Opening exclude namespaces configuration file with $(echo "$EDIT_CMD" | awk '{print $1}')..."
    $EDIT_CMD "$EXCLUDE_FILE"

    echo "Configuration updated successfully!"
    echo "Run 'k8sec list-services' to refresh the services list with the new configuration."
}

should_exclude_namespace() {
    local namespace="$1"

    if [ ! -f "$EXCLUDE_FILE" ]; then
        return 1
    fi

    while IFS= read -r pattern || [ -n "$pattern" ]; do

        [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue

        pattern=$(echo "$pattern" | tr -d '[:space:]')

        if [[ "$pattern" == *\* ]]; then
            prefix="${pattern%\*}"
            if [[ "$namespace" == "$prefix"* ]]; then
                return 0
            fi
        elif [[ "$namespace" == "$pattern" ]]; then
            return 0
        fi
    done <"$EXCLUDE_FILE"

    return 1
}

list_services() {
    echo "Generating services.json..."

    namespaces_json=""
    for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        if should_exclude_namespace "$ns"; then
            echo "Skipping excluded namespace: $ns"
            continue
        fi

        services_json=""
        svc_names=$(kubectl get services -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

        for svc in $svc_names; do
            svc_type=$(kubectl get service "$svc" -n "$ns" -o jsonpath='{.spec.type}' 2>/dev/null || echo "Unknown")
            svc_cluster_ip=$(kubectl get service "$svc" -n "$ns" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "None")

            service_entry=$(jq -n --arg name "$svc" --arg type "$svc_type" --arg ip "$svc_cluster_ip" \
                '{name: $name, type: $type, clusterIP: $ip}')

            if [ -z "$services_json" ]; then
                services_json="$service_entry"
            else
                services_json="$services_json, $service_entry"
            fi
        done

        namespace_entry=$(jq -n --arg ns "$ns" --argjson svcs "[$services_json]" \
            '{namespace: $ns, services: $svcs}')

        if [ -z "$namespaces_json" ]; then
            namespaces_json="$namespace_entry"
        else
            namespaces_json="$namespaces_json, $namespace_entry"
        fi
    done

    jq -n --argjson ns_svcs "[$namespaces_json]" \
        '{namespaces_and_services: $ns_svcs}' >"$SERVICES_JSON"

    echo "services.json generated successfully at $SERVICES_JSON!"
}

fetch_secrets() {
    SERVICE_NAME=$1
    ENV_TYPE=${2:-"qa"}
    CONFIG_TYPE=${3:-"auto"}

    if [ ! -f "$SERVICES_JSON" ]; then
        echo "Error: services.json not found in $SERVICES_JSON"
        echo "Run '$0 list-services' first to generate services.json"
        exit 1
    fi

    NAMESPACES=$(jq -r ".namespaces_and_services[] | select(.services[].name == \"$SERVICE_NAME\") | .namespace" "$SERVICES_JSON")

    if [ -z "$NAMESPACES" ] || [ "$NAMESPACES" == "" ]; then
        echo "Error: Service '$SERVICE_NAME' not found in services.json"
        exit 1
    fi

    FILTERED_NAMESPACE=""
    while read -r ns; do
        if [[ "$ns" == *"-$ENV_TYPE" ]] || [[ "$ns" == *"$ENV_TYPE-"* ]]; then
            FILTERED_NAMESPACE="$ns"
            break
        fi
    done <<<"$NAMESPACES"

    if [ -z "$FILTERED_NAMESPACE" ]; then
        FILTERED_NAMESPACE=$(echo "$NAMESPACES" | head -1)
        echo "Warning: No namespace found for environment '$ENV_TYPE'. Using '$FILTERED_NAMESPACE' instead."
    else
        echo "Found service '$SERVICE_NAME' in namespace '$FILTERED_NAMESPACE' for environment '$ENV_TYPE'"
    fi

    NAMESPACE="$FILTERED_NAMESPACE"

    POD_NAME=$(kubectl get pods -n "$NAMESPACE" | grep "$SERVICE_NAME" | grep -v "Terminating" | head -1 | awk '{print $1}')

    if [ -z "$POD_NAME" ]; then
        echo "Error: No running pod found for service '$SERVICE_NAME' in namespace '$NAMESPACE'"
        exit 1
    fi

    echo "Found pod: $POD_NAME"

    if [ "$CONFIG_TYPE" == "auto" ]; then
        if [[ "$SERVICE_NAME" == *"-node" ]]; then
            CONFIG_FILE=".env"
        else
            CONFIG_FILE="config.json"
        fi
    elif [ "$CONFIG_TYPE" == "config" ]; then
        CONFIG_FILE="config.json"
    elif [ "$CONFIG_TYPE" == "env" ]; then
        CONFIG_FILE=".env"
    else
        echo "Error: Invalid config type. Use 'config' or 'env'"
        exit 1
    fi

    echo "Attempting to fetch $CONFIG_FILE from pod..."

    TEMP_FILE="/tmp/k8s_config_$(date +%s).tmp"
    if [ "$CONFIG_FILE" == "config.json" ]; then
        POSSIBLE_PATHS=(
            "/data/projects/*/config.json"
            "/data/projects/*/config/config.json"
            "/app/config.json"
            "/config.json"
        )

        for PATH_TO_TRY in "${POSSIBLE_PATHS[@]}"; do
            echo "Searching path: $PATH_TO_TRY"
            CONFIG_PATHS=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "find $PATH_TO_TRY 2>/dev/null || echo ''")

            if [ -n "$CONFIG_PATHS" ]; then
                FIRST_CONFIG_PATH=$(echo "$CONFIG_PATHS" | head -1)
                echo "Found config at: $FIRST_CONFIG_PATH"
                kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat "$FIRST_CONFIG_PATH" | tee "$TEMP_FILE"
                cat "$TEMP_FILE" | pbcopy
                echo "Config copied to clipboard!"
                rm "$TEMP_FILE"
                exit 0
            fi
        done
    else
        POSSIBLE_PATHS=(
            "/data/projects/*/.env"
            "/data/projects/*/config/.env"
            "/app/.env"
            "/.env"
        )

        for PATH_TO_TRY in "${POSSIBLE_PATHS[@]}"; do
            echo "Searching path: $PATH_TO_TRY"
            ENV_PATHS=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c "find $PATH_TO_TRY 2>/dev/null || echo ''")

            if [ -n "$ENV_PATHS" ]; then
                FIRST_ENV_PATH=$(echo "$ENV_PATHS" | head -1)
                echo "Found .env at: $FIRST_ENV_PATH"
                kubectl exec -n "$NAMESPACE" "$POD_NAME" -- cat "$FIRST_ENV_PATH" | tee "$TEMP_FILE"
                cat "$TEMP_FILE" | pbcopy
                echo ".env file copied to clipboard!"
                rm "$TEMP_FILE"
                exit 0
            fi
        done
    fi

    echo "Error: Could not find $CONFIG_FILE in pod. You may need to connect manually:"
    echo "kubectl exec -it -n $NAMESPACE $POD_NAME -- sh"

    trap 'rm -f "$TEMP_FILE" 2>/dev/null' EXIT
    exit 1
}

if [ ! -f "$EXCLUDE_FILE" ]; then
    echo "# List of namespaces to exclude from the services list" >"$EXCLUDE_FILE"
    echo "# Use asterisk (*) for prefix matching (e.g., 'namespace-*' excludes all namespaces starting with 'namespace-')" >>"$EXCLUDE_FILE"
    echo "# Example:" >>"$EXCLUDE_FILE"
    echo "# kube-system" >>"$EXCLUDE_FILE"
    echo "# kube-public" >>"$EXCLUDE_FILE"
    echo "# namespace-*" >>"$EXCLUDE_FILE"
    echo "Created exclude namespaces file at $EXCLUDE_FILE"
fi

if [ $# -eq 0 ]; then
    usage
fi

if [ "$1" = "list-services" ]; then
    list_services
elif [ "$1" = "config" ]; then
    config
else
    fetch_secrets "$@"
fi
