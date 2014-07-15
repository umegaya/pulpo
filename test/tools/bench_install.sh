#!/bin/bash

# get echoserver
git clone https://github.com/methane/echoserver.git /tmp/echoserver

# create package dir
mkdir -p /tmp/packages/

# install go
wget http://golang.org/dl/go1.3.linux-amd64.tar.gz /tmp/packages/go.tar.gz
tar -C /usr/local -xzf /tmp/packages/go.tar.gz

# install node
wget http://nodejs.org/dist/v0.10.29/node-v0.10.29.tar.gz /tmp/packages/node.tar.gz
pushd /tmp/packages
tar -zxf node.tar.gz
pushd node-v0.10.29
./configure && make && make install
popd
popd

# install luajit 2.1.0 alpha
pushd /tmp/luajit-2.0
git checkout v2.1
make && $SUDO make install
popd

# build echo servers
pushd /tmp/echoserver
make all server_go
popd
