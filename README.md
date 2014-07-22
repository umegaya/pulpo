pulpo
=====

multi-thread network server library build with coroutine and luajit FFI at ground level


install
=======

git clone this repo and run install.sh
or
moonrocks install pulpo


API
===
```
pulpo.poller
 poller.new
 poller.newio
 poller.add_handler
pulpo.socket
 socket.setsockopt
 socket.stream
 socket.datagram
 socket.unix_domain
pulpo.event
 event.wait
 event.select
 event.new
  emitter:emit
pulpo.tentacle
 tentecle.new
  run
pulpo.shared_memory
 shared_memory.__index
pulpo.run
pulpo.stop
pulpo.find_thread
pulpo.evloop
pulpo.evloop.{module}
 pulpo.evloop.task
  task.new
  task.newgroup
 pulpo.evloop.clock
  clock.new
   clock:alarm
   clock:sleep
pulpo.evloop.io.{module}
 io:read
 io:wait_read
 io:write
 io:wait_write
 pulpo.evloop.io.tcp
  tcp.listen
  tcp.connect
 pulpo.evloop.io.ssl
  ssl.listen
  ssl.connect
 pulpo.evloop.io.timer
  timer.new
 pulpo.evloop.io.pipe
  pipe.new
 pulpo.evloop.io.sigfd
  sigfd.new
  sigfd.newgroup
 pulpo.evloop.io.poller
  poller.new
 pulpo.evloop.io.linda
  linda.new
```

