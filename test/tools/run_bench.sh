pushd /tmp/echoserver

# 0. create real bench.sh to execute
sed -i s/sag15/localhost/g bench.sh
if [ "$1" != "" ]; then
	sed -i s/-c50/-c$1/g bench.sh
fi
if [ "$2" != "" ]; then
	sed -i s/-h10000/-h$2/g bench.sh
fi

pid=0
echo "============= 1. pulpo thread = 1 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 1 5000 &
popd
pid=$!
./bench.sh
kill -9 $pid

echo "============= 2. go GOMAXPROC=1 ============="
./server_go &
pid=$!
./bench.sh
kill -9 $pid

echo "============= 3. nodejs ============="
node server_node.js &
pid=$!
./bench.sh
kill -9 $pid

echo "============= 4. go GOMAXPROC=4 ============="
GOMAXPROC=4 ./server_go &
pid=$!
./bench.sh
kill -9 $pid

echo "============= 5. pulpo thread = 4 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 4 5000 &
popd
pid=$!
./bench.sh
kill -9 $pid

echo "============= 5. pulpo(luajit 2.1) thread = 4 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit-2.1.0-alpha test/tools/listen.lua 4 5000 &
popd
pid=$!
./bench.sh
kill -9 $pid

