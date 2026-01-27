#!/bin/bash

# Version Dashboard Generator
# Fetches versions from Harbor registry and updates README.md

set -e

README_FILE="README.md"
HARBOR_URL="https://842775dh.c1.gra9.container-registry.ovh.net"
HARBOR_AUTH="${HARBOR_USER}:${HARBOR_TOKEN}"

# Projects to scan
PROJECTS=("flowmaker.core" "flowmaker.boxes" "datacatalog")

# Check if image has "official" tag in Harbor
is_official() {
    local project=$1
    local repo=$2

    local has_official=$(curl -s -u "$HARBOR_AUTH" \
        "${HARBOR_URL}/api/v2.0/projects/${project}/repositories/${repo}/artifacts?page_size=50" \
        | jq -r '[.[].tags[]?.name] | if index("official") then "yes" else "no" end')

    [ "$has_official" = "yes" ]
}

echo "Starting version fetch from Harbor..."

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
        | cut -d'T' -f1)

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
        *) display_name="$project" ;;
    esac

    cat >> "$README_FILE" << EOF
## $display_name

| Component | Version | Published | Status |
|-----------|---------|-----------|--------|
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

        # Check if official (has "official" tag in Harbor)
        if is_official "$project" "$repo_name"; then
            status="![Official](https://img.shields.io/badge/Official-✓-green)"
        else
            status=""
        fi

        echo "| $display_repo | \`$version\` | $date | $status |" >> "$README_FILE"
    done

    echo "" >> "$README_FILE"
done

# Add footer
cat >> "$README_FILE" << 'EOF'
---

*Auto-updated daily from [Harbor Registry](https://842775dh.c1.gra9.container-registry.ovh.net)*
EOF

# Replace date placeholder
sed -i "s/DATE_PLACEHOLDER/$(date -u '+%B %d, %Y at %H:%M UTC')/" "$README_FILE"

echo "Done! README.md updated."
