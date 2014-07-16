if [ "$4" != "" ]; then
ulimit -n $4
else
ulimit -n 4096
fi

pushd /tmp/echoserver

# 0. create real bench.sh to execute
sed -i s/sag15/127.0.0.1/g bench.sh
if [ "$1" != "" ]; then
	sed -i s/-o2/-o$1/g bench.sh
else
	sed -i s/-o2/-o16/g bench.sh
fi
if [ "$2" != "" ]; then
	sed -i s/-c50/-c$2/g bench.sh
fi
if [ "$3" != "" ]; then
	sed -i s/-h10000/-h$3/g bench.sh
fi


echo "client script ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
cat bench.sh

pid=0
echo "============= 1. pulpo thread = 1 ============="
pushd /tmp/pulpo
git pull
LD_PRELOAD=libpthread.so.0 luajit test/poller.lua # build cdefs
LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 1 5000 &
sleep 1s
popd
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

echo "============= 2. go ============="
./server_go &
sleep 1s
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

echo "============= 3. pulpo(luajit 2.1) thread = 1 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit-2.1.0-alpha test/tools/listen.lua 1 5000 &
sleep 1s
popd
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

if [ "$TEST_NODEJS" != "" ]; then
echo "============= 4. nodejs ============="
node server_node.js &
sleep 1s
pid=$!
./bench.sh
kill -9 $pid
sleep 1s
fi

echo "============= 5. c/c++ ============="
./server_epoll &
sleep 1s
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

echo "============= 6. go GOMAXPROC=4 ============="
GOMAXPROC=4 ./server_go &
sleep 1s
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

echo "============= 7. pulpo thread = 4 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 4 5000 &
sleep 1s
popd
pid=$!
./bench.sh
kill -9 $pid
sleep 1s

echo "============= 8. pulpo(luajit 2.1) thread = 4 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit-2.1.0-alpha test/tools/listen.lua 4 5000 &
sleep 1s
popd
pid=$!
./bench.sh
kill -9 $pid


