#!/bin/bash
if [ "$FROM_DOCKER" = "" ]; then
	SUDO=sudo
else
	SUDO=
fi
CHECK=`luajit -v`
LUAJIT_VERSION=master
if [ "$CHECK" = "" ];
then 
pushd tmp
git clone http://luajit.org/git/luajit-2.0.git
pushd luajit-2.0
make && $SUDO make install
popd
popd
fi
CHECK=`which tcc`
TCC_VERSION=release_0_9_26
TCC_LIB=libtcc.so
TCC_LIB_NAME=$TCC_LIB.1.0
if [ "$CHECK" = "" ];
then
pushd tmp
git clone --depth 1 git://repo.or.cz/tinycc.git --branch $TCC_VERSION
pushd tinycc
$SUDO ./configure && make DISABLE_STATIC=1 && make install
$SUDO cp $TCC_LIB_NAME /usr/local/lib/
$SUDO ln -s /usr/local/lib/$TCC_LIB_NAME /usr/local/lib/$TCC_LIB
$SUDO sh -c "echo '/usr/local/lib' > /etc/ld.so.conf.d/tcc.conf"
$SUDO ldconfig
popd
popd
fi
git clone https://github.com/umegaya/ffiex.git ~/ffiex
pushd ~/ffiex
$SUDO bash install.sh
popd
