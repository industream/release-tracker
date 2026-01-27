#!/bin/bash

# Version Dashboard Generator
# Fetches versions from Harbor registry and updates README.md

set -e

README_FILE="README.md"
HARBOR_URL="https://842775dh.c1.gra9.container-registry.ovh.net"
HARBOR_AUTH="${HARBOR_USER}:${HARBOR_TOKEN}"

# Projects to scan
PROJECTS=("flowmaker.core" "flowmaker.boxes" "datacatalog" "uifusion" "timeseries" "uimaker" "grafana")

# Get Docker labels from image
get_docker_labels() {
    local project=$1
    local repo=$2
    local version=$3

    if [ "$version" = "N/A" ]; then
        echo "{}"
        return
    fi

    # Get manifest (could be index or direct manifest)
    local manifest=$(curl -sL -u "$HARBOR_AUTH" \
        --header "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
        "${HARBOR_URL}/v2/${project}/${repo}/manifests/${version}" 2>/dev/null)

    local config_digest=""

    # Check if it's a manifest index (multi-arch) or direct manifest
    local media_type=$(echo "$manifest" | jq -r '.mediaType // empty' 2>/dev/null)

    if [[ "$media_type" == *"index"* ]] || [[ "$media_type" == *"list"* ]]; then
        # Multi-arch: get amd64 digest first
        local amd64_digest=$(echo "$manifest" | jq -r '.manifests[]? | select(.platform.architecture=="amd64" and .platform.os=="linux") | .digest' 2>/dev/null)
        if [ -z "$amd64_digest" ]; then
            echo "{}"
            return
        fi
        # Get config from amd64 manifest
        config_digest=$(curl -sL -u "$HARBOR_AUTH" \
            --header "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
            "${HARBOR_URL}/v2/${project}/${repo}/manifests/${amd64_digest}" 2>/dev/null \
            | jq -r '.config.digest' 2>/dev/null)
    else
        # Single-arch: config is directly in manifest
        config_digest=$(echo "$manifest" | jq -r '.config.digest // empty' 2>/dev/null)
    fi

    if [ -z "$config_digest" ]; then
        echo "{}"
        return
    fi

    # Get labels from config blob
    curl -sL -u "$HARBOR_AUTH" \
        "${HARBOR_URL}/v2/${project}/${repo}/blobs/${config_digest}" 2>/dev/null \
        | jq -r '.config.Labels // {}' 2>/dev/null
}

# Generate status badges from Docker labels
get_status_badges() {
    local labels=$1
    local badges=""

    # Check official label
    local official=$(echo "$labels" | jq -r '.official // empty')
    if [ "$official" = "true" ]; then
        badges="${badges}![Official](https://img.shields.io/badge/Official-✓-green) "
    fi

    # Check deprecated label
    local deprecated=$(echo "$labels" | jq -r '.deprecated // empty')
    if [ "$deprecated" = "true" ]; then
        badges="${badges}![Deprecated](https://img.shields.io/badge/Deprecated-⚠-orange) "
    fi

    # Check experimental label
    local experimental=$(echo "$labels" | jq -r '.experimental // empty')
    if [ "$experimental" = "true" ]; then
        badges="${badges}![Experimental](https://img.shields.io/badge/Experimental-🧪-blue) "
    fi

    # Check beta label
    local beta=$(echo "$labels" | jq -r '.beta // empty')
    if [ "$beta" = "true" ]; then
        badges="${badges}![Beta](https://img.shields.io/badge/Beta-β-yellow) "
    fi

    echo "$badges"
}

echo "Starting version fetch from Harbor..."

# Initialize deprecated items list
DEPRECATED_ITEMS=""

# Start README
cat > "$README_FILE" << 'EOF'
# Industream Version Dashboard

Current versions of all Industream platform components.

> Last updated: DATE_PLACEHOLDER

EOF

fetch_latest_version() {
    local project=$1
    local repo=$2

    # Get artifacts sorted by push time, extract version tag (not "latest", not "-dev")
    local result=$(curl -s -u "$HARBOR_AUTH" \
        "${HARBOR_URL}/api/v2.0/projects/${project}/repositories/${repo}/artifacts?page_size=10&sort=-push_time" \
        | jq -r '[.[].tags[]? | select(.name != null)] | .[].name' \
        | grep -v "^latest$" \
        | grep -v "^dev$" \
        | grep -v "\-dev" \
        | grep -v "\-secure" \
        | grep -E "^v?[0-9]" \
        | head -1)

    echo "${result:-N/A}"
}

fetch_push_date() {
    local project=$1
    local repo=$2
    local version=$3

    if [ "$version" = "N/A" ]; then
        echo "-"
        return
    fi

    local date=$(curl -s -u "$HARBOR_AUTH" \
        "${HARBOR_URL}/api/v2.0/projects/${project}/repositories/${repo}/artifacts?page_size=10&sort=-push_time" \
        | jq -r --arg v "$version" '[.[] | select(.tags[]?.name == $v)][0].push_time // empty' \
        | cut -d'T' -f1 \
        | sed 's/-/‑/g')

    echo "${date:--}"
}

# Process each project
for project in "${PROJECTS[@]}"; do
    echo "Processing project: $project"

    # Get project display name
    case $project in
        "flowmaker.core") display_name="Flowmaker Core" ;;
        "flowmaker.boxes") display_name="Flowmaker Workers" ;;
        "datacatalog") display_name="DataCatalog" ;;
        "uifusion") display_name="UIFusion" ;;
        "timeseries") display_name="Timeseries" ;;
        "uimaker") display_name="UIMaker" ;;
        "grafana") display_name="Grafana" ;;
        *) display_name="$project" ;;
    esac

    # Reset project-level deprecated list
    PROJECT_DEPRECATED=""

    cat >> "$README_FILE" << EOF
## $display_name

| Component | Image | Version | Published Date | Status |
|-----------|-------|---------|----------------|--------|
EOF

    # Get repositories (exclude dev/, industream/, etcd3-browser)
    repos=$(curl -s -u "$HARBOR_AUTH" \
        "${HARBOR_URL}/api/v2.0/projects/${project}/repositories?page_size=100" \
        | jq -r '.[].name' \
        | grep -v "/dev/" \
        | grep -v "/industream/" \
        | grep -v "etcd3-browser" \
        | grep -v "/uifusion$" \
        | grep -v "flow-box-notifications$" \
        | grep -v "flow-box-timeseries$" \
        | grep -v "flow-box-timeseries-datasink$" \
        | grep -v "flow-box-timeseries-worker$" \
        | sort)

    for full_repo in $repos; do
        # Extract repo name without project prefix
        repo_name="${full_repo#${project}/}"

        echo "  Fetching: $repo_name"

        version=$(fetch_latest_version "$project" "$repo_name")
        date=$(fetch_push_date "$project" "$repo_name" "$version")

        # Clean display name
        display_repo=$(echo "$repo_name" | sed 's/flow-box-//' | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

        # Harbor link
        harbor_link="${HARBOR_URL}/harbor/projects/${project}/repositories/${repo_name}"

        # Get Docker labels and generate status badges
        labels=$(get_docker_labels "$project" "$repo_name" "$version")

        # Check if deprecated
        is_deprecated=$(echo "$labels" | jq -r '.deprecated // empty')

        if [ "$is_deprecated" = "true" ]; then
            # Add to project-level deprecated list
            PROJECT_DEPRECATED="${PROJECT_DEPRECATED}- ~~[$display_repo]($harbor_link)~~ \`$version\`
"
            # Add to global deprecated list
            DEPRECATED_ITEMS="${DEPRECATED_ITEMS}| <sub>[$display_repo]($harbor_link)</sub> | <sub>\`$repo_name\`</sub> | <sub>\`$version\`</sub> | <sub>\`$date\`</sub> | <sub>$display_name</sub> |
"
        else
            status=$(get_status_badges "$labels")
            echo "| [$display_repo]($harbor_link) | \`$repo_name\` | \`$version\` | \`$date\` | $status |" >> "$README_FILE"
        fi
    done

    # Add project-level deprecated subsection if any
    if [ -n "$PROJECT_DEPRECATED" ]; then
        cat >> "$README_FILE" << 'EOF'

> [!CAUTION]
> **Deprecated components:**
EOF
        echo "$PROJECT_DEPRECATED" >> "$README_FILE"
    fi

    echo "" >> "$README_FILE"
done

# Add deprecated section if there are deprecated items
if [ -n "$DEPRECATED_ITEMS" ]; then
    cat >> "$README_FILE" << 'EOF'
## Deprecated

> [!CAUTION]
> **These components are no longer maintained and will be removed in a future version.**

| Component | Image | Version | Published Date | Origin |
|-----------|-------|---------|----------------|--------|
EOF
    echo "$DEPRECATED_ITEMS" >> "$README_FILE"
    echo "" >> "$README_FILE"
fi

# Add footer
cat >> "$README_FILE" << 'EOF'
---

*Auto-updated daily from [Harbor Registry](https://842775dh.c1.gra9.container-registry.ovh.net)*
EOF

# Replace date placeholder
sed -i "s/DATE_PLACEHOLDER/$(date -u '+%B %d, %Y at %H:%M UTC')/" "$README_FILE"

echo "Done! README.md updated."
