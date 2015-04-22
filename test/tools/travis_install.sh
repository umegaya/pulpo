#!/bin/bash
if [ "$FROM_DOCKER" = "" ]; then
	SUDO=sudo
else
	SUDO=
fi
## install luajit
CHECK=`luajit -v`
if [ "$CHECK" = "" ];
then 
pushd tmp
echo "luajit version:[$LUAJIT_VERSION]"
if [ "$LUAJIT_VERSION" = "" ]; then
git clone http://luajit.org/git/luajit-2.0.git
else
git clone http://luajit.org/git/luajit-2.0.git --branch $LUAJIT_VERSION
fi
pushd luajit-2.0
make && $SUDO make install
popd
popd
fi

# install tcc
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

# install luarocks
CHECK=`luarocks --version`
LUAROCKS_VERSION=2.1.2
if [ "$CHECK" = "" ]; then
pushd tmp
wget http://luarocks.org/releases/luarocks-$LUAROCKS_VERSION.tar.gz 
tar zxvf luarocks-$LUAROCKS_VERSION.tar.gz 
cd luarocks-$LUAROCKS_VERSION
./configure --prefix=/usr --with-lua=/usr/local/ --lua-suffix=jit --with-lua-include=/usr/local/include/luajit-2.0/
make && $SUDO make install
$SUDO rm -rf /usr/local/share/lua && ln -s /usr/share/lua /usr/local/share/lua
popd
fi

# install ffiex
pushd tmp
git clone https://github.com/umegaya/ffiex.git
pushd ffiex
$SUDO bash install.sh
popd
popd

# install jemalloc
JEMALLOC_VERSION=3.6.0
pushd tmp
git clone https://github.com/jemalloc/jemalloc.git --branch $JEMALLOC_VERSION
pushd jemalloc
autoconf && ./configure && make && $SUDO make install
popd
popd

HTTP_PARSER_VERSION=umegaya/feature/so
pushd tmp
git clone https://github.com/umegaya/picohttpparser --branch $HTTP_PARSER_VERSION
pushd picohttpparser
make so && objcopy -S libpicohttpparser.so && make install_so
popd
popd