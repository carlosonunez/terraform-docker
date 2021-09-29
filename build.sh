#!/usr/bin/env bash
#vi: set ft=bash:
if test -e "$(dirname "$0")/.env"
then
  # Quoting this will break it.
  # shellcheck  disable=SC2046
  export $(grep -Ev '^#' "$(dirname "$0")/.env" | xargs -0)
fi

DOCKER_HUB_USERNAME="${DOCKER_HUB_USERNAME?Please provide the username to Docker Hub.}"
DOCKER_HUB_PASSWORD="${DOCKER_HUB_PASSWORD?Please provide the password to Docker Hub.}"
DOCKER_HUB_REPO="${DOCKER_HUB_REPO:-$DOCKER_HUB_USERNAME/terraform}"
REBUILD="${REBUILD:-false}"
# This was the first publicly-available version with ARM-compiled builds
MIN_TERRAFORM_MAJOR_VERSION=0
MIN_TERRAFORM_MINOR_VERSION=13
MIN_TERRAFORM_PATCH_VERSION=5
ONLY_SELECT_TF_STABLE_VERSIONS_RE='a href.*terraform_[0-9]{1}\.[0-9]{1,2}\.[0-9]{1,2}<'
CAPTURE_VERSION_INSIDE_OF_HREF_RE='s/.*>terraform_(.*)<.*$/\1/'

log_into_docker_hub_or_fail() {
  if ! docker login -u "$DOCKER_HUB_USERNAME" -p "$DOCKER_HUB_PASSWORD" >/dev/null
  then
    >&2 echo "ERROR: Unable to log into Docker Hub; see logs for more details."
    exit 1
  fi
}

get_terraform_versions() {
  curl -s -H "Accept: application/json" https://releases.hashicorp.com/terraform/ | \
    grep -E "$ONLY_SELECT_TF_STABLE_VERSIONS_RE" | \
    sed -E "$CAPTURE_VERSION_INSIDE_OF_HREF_RE"
}

version_is_supported() {
  version="$1"
  major=$(echo "$version" | cut -f1 -d .)
  minor=$(echo "$version" | cut -f2 -d .)
  patch=$(echo "$version" | cut -f3 -d .)
  test "$major" -gt "$MIN_TERRAFORM_MAJOR_VERSION" ||
    { test "$major" -eq "$MIN_TERRAFORM_MAJOR_VERSION" &&
      test "$minor" -gt "$MIN_TERRAFORM_MINOR_VERSION"; } ||
    { test "$major" -eq "$MIN_TERRAFORM_MAJOR_VERSION" &&
      test "$minor" -eq "$MIN_TERRAFORM_MINOR_VERSION" &&
      test "$patch" -ge "$MIN_TERRAFORM_PATCH_VERSION" ; }
}

get_existing_docker_image_tags() {
  curl -s "https://registry.hub.docker.com/v2/repositories/$DOCKER_HUB_REPO/tags?page_size=10000" | \
    jq -r '.results[] | select(.name | contains("-") | not) | .name'
}

image_already_exists() {
  if grep -Eiq '^true$' <<< "$REBUILD"
  then
    >&2 echo "INFO: Skipping existing image check, as REBUILD=true"
    return 1
  fi
  grep -q "$1" <<< "$2"
}

build_and_push_new_image() {
  _build() {
    docker build -t "$image_name" \
      --platform "$arch" \
      --build-arg VERSION="$version" \
      --build-arg ARCH="$arch" .
  }

  _push() {
    docker push "$image_name"
  }

  _push_linked_manifest() {
    version="$1"
    unified_tag="$DOCKER_HUB_REPO:$version"
    docker manifest create "$unified_tag" \
      --amend "${unified_tag}-amd64" \
      --amend "${unified_tag}-arm64" &&
    docker manifest push "$unified_tag"
  }

  version="$1"
  is_latest="${2:-false}"
  for arch in arm64 amd64
  do
    if test "$is_latest" == "true"
    then
      >&2 echo "INFO: Tagging Terraform version [$version] as latest"
      image_name="$DOCKER_HUB_REPO:latest"
      docker tag "$DOCKER_HUB_REPO:$version" "$image_name" && _push "$image_name"
    else
      image_name="$DOCKER_HUB_REPO:${version}-${arch}"
      >&2 echo "INFO: Building Terraform v$version $arch"
      if ! ( _build && _push )
      then
        >&2 echo "ERROR: Failed to build and push version $version; stopping"
        exit 1
      fi
    fi
  done

  test "$is_latest" == "true" || _push_linked_manifest "$version"
}

log_into_docker_hub_or_fail
existing_tags=$(get_existing_docker_image_tags)
versions_needing_an_image=""
first_image_in_list=true
latest_version=""
while read -r version
do
  if test "$first_image_in_list" == "true"
  then
    >&2 echo "INFO: Latest Terraform version is $version"
    latest_version="$version"
    first_image_in_list=false
  fi
  ! version_is_supported "$version" && continue
  if ! image_already_exists "$version" "$existing_tags"
  then
    if test "$1" == "--alert-only"
    then
      versions_needing_an_image="$versions_needing_an_image,$version"
    else
      build_and_push_new_image "$version"
    fi
  else
    >&2 echo "INFO: Docker image already exists for Terraform v$version"
  fi
done <<< "$(get_terraform_versions)"
build_and_push_new_image "$latest_version" "true"

# GitHub Actions doesn't support ARM runners, and spinning one up in AWS that does nothing
# is a waste of money. Instead, alert me when a new version comes out so I can run this script.
if ! test -z "$versions_needing_an_image"
then
  versions_fixed=$(echo "$versions_needing_an_image" | sed 's/^,//; s/,/, /g')
  >&2 echo "INFO: Build Docker images for these Terraform versions: [$versions_fixed]"
  exit 1
fi
