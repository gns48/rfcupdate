#!/bin/sh

URL="http://rfc-editor.org/in-notes"
INDEX=rfc-index.txt

rm -f $INDEX
wget ${URL}/${INDEX}

rfclist=`./rfcupdate absent | grep ftp | awk -v urlx="${URL}" '{printf("%s/rfc%s.txt\n", urlx, $2)}'` 

if [ -n "${rfclist}" ] ; then
   echo ${rfclist} | xargs wget
   ./rfcupdate toss
fi
