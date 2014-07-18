#!/bin/bash

ulimit -n 4096

killall -9 server_go
killall -9 server_epoll
killall -9 luajit
killall -9 luajit-2.1.0-alpha
killall -9 node

sleep 3s

pushd $1
eval "$2" &
sleep 1s
popd
