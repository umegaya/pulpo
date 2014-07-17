ulimit -n 4096
pushd /tmp/echoserver
git reset --hard

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
SSL_CMD=
if [ "$4" != "" ]; then
	SSL_CMD="-p 2222 root@$4"
fi
if [ "$5" != "" ]; then
	SSL_CMD=$5
fi

run_bench() {
	WD=/tmp/echoserver
	if [ "$2" != "" ]; then
		WD=$2
	fi
	if [ "$SSL_CMD" != "" ]; then
		ssh $SSL_CMD "/tmp/pulpo/test/tools/run_remote.sh $WD $1"
		sleep 1s
		./bench.sh
		sleep 1s
	else
		bash /tmp/pulpo/test/tools/run_remote.sh $WD "$1"
		sleep 1s
		./bench.sh
		sleep 1s
	fi
}
	
echo "client script ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
cat bench.sh
pid=0

echo "============= 1. pulpo thread = 1 ============="
pushd /tmp/pulpo
LD_PRELOAD=libpthread.so.0 luajit test/poller.lua # build cdefs
popd
run_bench "LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 1 5000" /tmp/pulpo

echo "============= 2. go ============="
run_bench "./server_go"

echo "============= 3. pulpo(luajit 2.1) thread = 1 ============="
run_bench "LD_PRELOAD=libpthread.so.0 luajit-2.1.0-alpha test/tools/listen.lua 1 5000" /tmp/pulpo

if [ "$TEST_NODEJS" != "" ]; then
echo "============= 4. nodejs ============="
run_bench "node server_node.js"
fi

echo "============= 5. c/c++ ============="
run_bench "./server_epoll"

echo "============= 6. go GOMAXPROC=4 ============="
run_bench "GOMAXPROC=4 ./server_go"

echo "============= 7. pulpo thread = 4 ============="
run_bench "LD_PRELOAD=libpthread.so.0 luajit test/tools/listen.lua 4 5000" /tmp/pulpo

echo "============= 8. pulpo(luajit 2.1) thread = 4 ============="
run_bench "LD_PRELOAD=libpthread.so.0 luajit-2.1.0-alpha test/tools/listen.lua 4 5000" /tmp/pulpo


