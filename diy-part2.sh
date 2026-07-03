#!/bin/bash
#
# Combined DIY Part 2 Script
# Handles: Rust fix, build date
#
set -x

# Fix Rust compilation (disable download-ci-llvm)
sed -i 's/ci-llvm=true/ci-llvm=false/g' feeds/packages/lang/rust/Makefile

# Add build date to firmware filename
sed -i -e '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' \
       -e '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' include/image.mk
