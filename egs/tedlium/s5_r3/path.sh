# return to the root folder of kaldi
export KALDI_ROOT=`pwd`/../../..

# if the env.sh exists, excute it
[ -f $KALDI_ROOT/tools/env.sh ] && . $KALDI_ROOT/tools/env.sh

# add openfst, current working directory, sph2pipe, and kaldi root directory to path
# openfst is a library for constructing, combining, optimizing, and searching weighted finite-state transducers (FSTs), 
# see https://www.openfst.org/twiki/bin/view/FST/WebHome
# sph2pipe is a tool that convert sphere files to other formats, 
# see https://www.ldc.upenn.edu/language-resources/tools/sphere-conversion-tools
export PATH=$PWD/utils/:$KALDI_ROOT/tools/openfst/bin:$PWD:$PATH:$KALDI_ROOT/tools/sph2pipe_v2.5

# if common_path.sh doesn't exist, report error and exit.
[ ! -f $KALDI_ROOT/tools/config/common_path.sh ] && echo >&2 "The standard file $KALDI_ROOT/tools/config/common_path.sh is not present -> Exit!" && exit 1

# add src bin directories to path
. $KALDI_ROOT/tools/config/common_path.sh

# set locale variables to default C(POSIX) environment. 
# POSIX specifies the minimal environment for C-language translation called the POSIX locale.
export LC_ALL=C
