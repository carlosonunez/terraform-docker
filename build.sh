#!/usr/bin/env bash
#vi: set ft=bash:
if test -e "$(dirname "$0")/.env"
then
  export $(egrep -v '^#' "$(dirname "$0")/.env" | xargs -0)
fi

DOCKER_HUB_USERNAME="${DOCKER_HUB_USERNAME?Please provide the username to Docker Hub.}"
DOCKER_HUB_PASSWORD="${DOCKER_HUB_PASSWORD?Please provide the password to Docker Hub.}"
DOCKER_HUB_REPO="${DOCKER_HUB_REPO:-$DOCKER_HUB_USERNAME/terraform}"
MIN_TERRAFORM_MAJOR_VERSION=0
MIN_TERRAFORM_MINOR_VERSION=11
MIN_TERRAFORM_PATCH_VERSION=15
MIN_TERRAFORM_VERSION_SUPPORTED="${MIN_TERRAFORM_MAJOR_VERSION}.${MIN_TERRAFORM_MINOR_VERSION}.${MIN_TERRAFORM_PATCH_VERSION}"
ONLY_SELECT_TF_STABLE_VERSIONS_RE='a href.*terraform_[0-9]{1}\.[0-9]{1,2}\.[0-9]{1,2}<'
CAPTURE_VERSION_INSIDE_OF_HREF_RE='s/.*>terraform_(.*)<.*$/\1/'

log_into_docker_hub_or_fail() {
  if ! docker login -u "$DOCKER_HUB_USERNAME" -p "$DOCKER_HUB_PASSWORD"
  then
    >&2 echo "ERROR: Unable to log into Docker Hub; see logs for more details."
    exit 1
  fi
}

get_terraform_versions() {
  curl -H "Accept: application/json" https://releases.hashicorp.com/terraform/ | \
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
  curl "https://registry.hub.docker.com/v2/repositories/$DOCKER_HUB_REPO/tags?page_size=10000" | \
    jq -r '.results[] | .name'
}

image_already_exists() {
  grep -q "$1" <<< "$2"
}

build_and_push_new_image() {
  _build() {
    docker build -t "$image_name" \
      --platform "$arch" \
      --progress plain \
      --build-arg VERSION="$version" \
      --build-arg ARCH="$arch" .
  }

  _test() {
    version="$(docker run --rm "$image_name" version)"
    rc=$?
    test "$rc" -eq 0 && ! test -z "$version"
  }

  _push() {
    docker push "$image_name"
  }

  _push_linked_manifest() {
    unified_tag="$DOCKER_HUB_REPO:$version"
    docker manifest create "$unified_tag" \
      --amend "${unified_tag}-amd64" \
      --amend "${unified_tag}-arm64" &&
    docker manifest push "$unified_tag"
  }

  version="$1"
  for arch in arm64 amd64
  do
    image_name="$DOCKER_HUB_REPO:${version}-${arch}"
    >&2 echo "INFO: Building Terraform v$version $arch"
    if ! ( _build && _test && _push )
    then
      >&2 echo "ERROR: Failed to build and push version $version; stopping"
      exit 1
    fi
  done

  _push_linked_manifest
}

log_into_docker_hub_or_fail
existing_tags=$(get_existing_docker_image_tags)
while read -r version
do
  if ! version_is_supported "$version"
  then
    >&2 echo "ERROR: Version older than minimum supported version $MIN_TERRAFORM_VERSION_SUPPORTED: $version"
    continue
  fi
  if ! image_already_exists "$version" "$existing_tags"
  then
    build_and_push_new_image "$version"
  fi
done <<< "$(get_terraform_versions)"
