#!/usr/bin/env bash
# Provision-time EBS mapping (EC2_VOLUME_IOPS/THROUGHPUT) and the live
# `set-disk-perf` command: flag parsing, range + ratio guards, and that a
# modify-volume is issued for every attached volume.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t BASE_DOMAIN=example.com OCP_VERSION=stable-4.22 \
       NET_CIDR=192.168.126.0/24 LIBVIRT_NET=rhwa
source "${DIR}/../lib/common.sh"
log(){ :; }; ok(){ :; }; warn(){ printf 'WARN %s\n' "$*" >>"$STUB_OUT"; }
source "${DIR}/../lib/aws.sh"

# ---- provision-time block-device-mapping -----------------------------------
# Baseline: no env vars -> no Iops/Throughput fields (uses the free gp3 baseline).
out="$(EC2_VOLUME_SIZE_GB=1000 EC2_VOLUME_IOPS= EC2_VOLUME_THROUGHPUT= _root_ebs_mapping /dev/sda1)"
case "$out" in *Iops*|*Throughput*) echo "FAIL: baseline mapping should carry neither Iops nor Throughput: $out"; exit 1;; esac
case "$out" in *"VolumeSize=1000,VolumeType=gp3"*) ;; *) echo "FAIL: bad baseline mapping: $out"; exit 1;; esac

# With both env vars set, both fields are provisioned.
out="$(EC2_VOLUME_SIZE_GB=1000 EC2_VOLUME_IOPS=16000 EC2_VOLUME_THROUGHPUT=1000 _root_ebs_mapping /dev/sda1)"
case "$out" in *"Iops=16000"*) ;; *) echo "FAIL: missing Iops: $out"; exit 1;; esac
case "$out" in *"Throughput=1000"*) ;; *) echo "FAIL: missing Throughput: $out"; exit 1;; esac

# Out-of-range provision values are rejected before launch.
( EC2_VOLUME_IOPS=99999 _root_ebs_mapping /dev/sda1 ) 2>/dev/null && { echo "FAIL: IOPS above EC2_MAX_IOPS accepted"; exit 1; } || true
( EC2_VOLUME_IOPS=100   _root_ebs_mapping /dev/sda1 ) 2>/dev/null && { echo "FAIL: IOPS below baseline accepted"; exit 1; } || true
# Throughput without enough IOPS for the 0.25 MiB/s-per-IOPS ratio is rejected.
# IOPS pinned empty (=baseline 3000, which only supports 750 MiB/s) so this
# tests the ratio, not the 12000 provision default.
( EC2_VOLUME_IOPS= EC2_VOLUME_THROUGHPUT=1000 _root_ebs_mapping /dev/sda1 ) 2>/dev/null && { echo "FAIL: throughput exceeding ratio at baseline accepted"; exit 1; } || true

# ---- live set-disk-perf -----------------------------------------------------
state_get(){ [[ "$1" == instance_id ]] && echo i-abc || echo ""; }
sleep(){ :; }   # never really wait in the modification poll
aws() {
  case "$2" in
    describe-instances)             echo "vol-aaa vol-bbb" ;;   # two attached volumes
    describe-volumes)               echo 3000 ;;                # current IOPS (ratio base)
    modify-volume)                  printf 'MODIFY %s\n' "$*" >>"$STUB_OUT" ;;
    describe-volumes-modifications) echo optimizing ;;          # already applying -> loop breaks
    *)                              echo "" ;;
  esac
}

# --iops only: a modify-volume per volume, carrying --iops and no --throughput.
: >"$STUB_OUT"; aws_set_disk_perf --iops 10000
assert_contains "$STUB_OUT" "MODIFY ec2 modify-volume --volume-id vol-aaa --iops 10000"
assert_contains "$STUB_OUT" "MODIFY ec2 modify-volume --volume-id vol-bbb --iops 10000"
assert_not_contains "$STUB_OUT" "--throughput"

# --throughput only, within the current-IOPS ratio (3000 IOPS -> <=750 MiB/s).
: >"$STUB_OUT"; aws_set_disk_perf --throughput 500
assert_contains "$STUB_OUT" "MODIFY ec2 modify-volume --volume-id vol-aaa --throughput 500"
assert_not_contains "$STUB_OUT" "--iops"

# Both flags together.
: >"$STUB_OUT"; aws_set_disk_perf --iops 12000 --throughput 1000
assert_contains "$STUB_OUT" "--volume-id vol-aaa --iops 12000 --throughput 1000"

# --throughput only ABOVE the current-IOPS ratio: skipped, no modify-volume
# (subshell: with every volume skipped the run dies "no volumes were modified").
: >"$STUB_OUT"; ( aws_set_disk_perf --throughput 1000 ) 2>/dev/null || true
assert_not_contains "$STUB_OUT" "MODIFY"
assert_contains     "$STUB_OUT" "skip vol-aaa"

# Guards / arg errors all exit non-zero.
( aws_set_disk_perf )                       2>/dev/null && { echo "FAIL: no args accepted"; exit 1; } || true
( aws_set_disk_perf --iops 80000 )          2>/dev/null && { echo "FAIL: IOPS above EC2_MAX_IOPS accepted"; exit 1; } || true
( aws_set_disk_perf --iops 2999 )           2>/dev/null && { echo "FAIL: IOPS below baseline accepted"; exit 1; } || true
( aws_set_disk_perf --throughput 2000 )     2>/dev/null && { echo "FAIL: throughput above EC2_MAX_THROUGHPUT accepted"; exit 1; } || true
( aws_set_disk_perf --throughput 100 )      2>/dev/null && { echo "FAIL: throughput below baseline accepted"; exit 1; } || true
( aws_set_disk_perf --bogus )               2>/dev/null && { echo "FAIL: unknown flag accepted"; exit 1; } || true

echo "PASS"
