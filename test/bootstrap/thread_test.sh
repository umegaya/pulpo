#!/bin/bash

i=0

while [ $i -lt $1 ]
do 
	printf '.'
	luajit test/tools/many_thread.lua
	if [ "$?" -ne "0" ]; then 
		break
	fi 
	i=$(($i + 1))
done
