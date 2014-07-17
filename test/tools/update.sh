#!/bin/bash
BRANCH=master
if [ "$1" != "" ]; then
	BRANCH=$1
fi
pushd /tmp/pulpo
git checkout $BRANCH
git reset --hard
git pull
popd

