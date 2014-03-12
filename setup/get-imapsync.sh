#!/bin/bash

. `dirname $0`/sdbs.inc


cd $PREFIX/src
wget https://github.com/imapsync/imapsync/archive/imapsync-1.584.zip
unzip imapsync-1.584.zip

cd imapsync-imapsync-1.584
perl -pi -e 's|#!/usr/bin/perl|#!/usr/bin/perl\nuse FindBin;\nuse lib \"\$FindBin::Bin/../../thirdparty/lib/perl5\";|' imapsync 
cp imapsync $PREFIX/bin
cd ..

rm -rf $PREFIX/src/imapsync-imapsync-1.584
rm -rf $PREFIX/src/imapsync-1.584.zip






        
