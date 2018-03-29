#!/bin/sh

arch=arm64

remote_host=iphone
remote_prefix=/var/root/frida-tests-$arch

core_tests=$(dirname "$0")
cd "$core_tests/../../build/tmp-ios-$arch/frida-core" || exit 1
. ../../frida-meson-env-macos-x86_64.rc
ninja || exit 1
cd tests
rsync -rLz frida-tests labrats "$remote_host:$remote_prefix/" || exit 1
ssh "$remote_host" "$remote_prefix/frida-tests" "$@"
