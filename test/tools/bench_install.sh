#!/bin/bash

# get echoserver
git clone https://github.com/methane/echoserver.git /tmp/echoserver

# create package dir
mkdir -p /tmp/packages/
pushd /tmp/packages

# install go
GO_VERSION=1.3.linux-amd64
wget http://golang.org/dl/go$GO_VERSION.tar.gz
tar -C /usr/local -xzf go$GO_VERSION.tar.gz

# install node
NODE_VERSION=v0.10.29
wget http://nodejs.org/dist/v0.10.29/node-$NODE_VERSION.tar.gz
tar -zxf node-$NODE_VERSION.tar.gz
pushd node-$NODE_VERSION
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
