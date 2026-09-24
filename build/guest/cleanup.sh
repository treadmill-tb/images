#!/bin/sh
set -eu

DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
apt-get clean
rm -rf /var/lib/apt/lists/*
