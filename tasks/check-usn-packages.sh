#!/usr/bin/env bash

set -euo pipefail

#
# This script goes through the list of ubuntu security notices (USNs) and makes sure that packages
# listed in every USN are available in apt repositories for installation.
# We do this to make sure that a newly released stemcell includes fixes for USNs that tirggered the build.
#

USN_JSON_URL="usn-log-in/usn-log.json"

function process_packages {
  local package_version_for_usn=("$@")

  for package_version in "${package_version_for_usn[@]}"
  do
    # single package
    package=$(echo "$package_version" | cut -d ':' -f1)
    version=$(echo "$package_version" | cut -d ':' -f2)

    if is_package_installed "$package";
    then
      echo "checking: $package"
      check_package "$package" "$version"
    else
      echo "skip: $package"
    fi
  done
}

function candidate_version_to_install {
  local package_name=$1
  local candidate
  candidate=$(sudo apt policy "$package_name" 2>/dev/null | grep Candidate | tr -s ' ' | cut -d ' ' -f3)
  echo "$candidate"
}

function check_package {
  local package=$1
  local version=$2
  local candidate_version

  candidate_version=$(candidate_version_to_install "$package")

  if ! dpkg --compare-versions "$candidate_version" ge "$version";
  then
    ALL_PACKAGE_VERSIONS_AVAILABLE=false
    echo -e "L \e[31mexpected version from USN: $version, available in repo: $candidate_version\e[0m"
  else
    echo -e "L repo version: $candidate_version matches USN version: $version"
  fi
}

function enable_esm {
  apt-get update
  apt-get install -y ca-certificates ubuntu-advantage-tools
  ua attach "${ESM_TOKEN}" --no-auto-enable
  ua enable esm-infra
}

function process_usns {
  local usn_log_json=$1

  mapfile -t usn_urls < <(jq -r '.url | select(.|test("USN"))' "$usn_log_json" | sort | uniq)

  for usn_url in "${usn_urls[@]}"
  do
    # list of packages
    echo -e "\n>>>>> $usn_url <<<<<"

    mapfile -t package_version_for_usn < <( curl -s "$usn_url.json" | jq --arg os $OS -r '.release_packages[$os][] | select(.is_source==false) | "\(.name):\(.version)"')
    process_packages "${package_version_for_usn[@]}"
  done
}

function is_package_installed {
  local package=$1
  echo "$INSTALLED_PACKAGES" | grep -q "$package$"
  return $?
}

if [[ -n "$ESM_TOKEN" ]]; then
  enable_esm
fi

if [[ -z "${OS}" ]]; then
  echo "Environment variable 'OS' must be set, and not empty"
  exit 1
fi

# Depends on apt package list being up-to-date, make sure apt-get update is run before this is executed
sudo apt-get update
INSTALLED_PACKAGES=$(cat bosh-linux-stemcell-builder/bosh-stemcell/spec/assets/dpkg-list-ubuntu-${OS}*.txt | sort | uniq | sed -e 's/:amd64//g')
ALL_PACKAGE_VERSIONS_AVAILABLE=true
process_usns "$USN_JSON_URL"

if [ "$ALL_PACKAGE_VERSIONS_AVAILABLE" != true ]
then
  echo "Not all vulnerable packages have available fixes yet, defering stemcell build."
  exit 1
else
  exit 0
fi
