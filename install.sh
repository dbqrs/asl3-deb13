#!/bin/bash

set -e

cd /tmp
wget https://repo.allstarlink.org/public/asl-apt-repos.deb13_all.deb
sudo dpkg -i asl-apt-repos.deb13_all.deb
sudo apt update
sudo apt install asl3-appliance-pc -y
