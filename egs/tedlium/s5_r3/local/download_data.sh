#!/usr/bin/env bash

# Copyright  2014  Nickolay V. Shmyrev
#            2014  Brno University of Technology (Author: Karel Vesely)
#            2016  John Hopkins University (author: Daniel Povey)
# Apache 2.0

mkdir -p db

cd db  ### Note: the rest of this script is executed from the directory 'db'.

# TED-LIUM database:
# if current host is in jhu domain
if [[ $(hostname -f) == *.clsp.jhu.edu ]] ; then
  # if the folder does not exist
  if [ ! -e TEDLIUM_release-3 ]; then
    # make a soft link to the source directory
    ln -sf /export/corpora5/TEDLIUM_release-3
  fi
  # $0 expands to the name of the shell or shell script, eg. -bash . see https://bash.cyberciti.biz/guide/$0
  echo "$0: linking the TEDLIUM data from /export/corpora5/TEDLIUM_release-3"
else
  # if folder not exist
  if [ ! -e TEDLIUM_release-3 ]; then
    # start to download the tedlium data, approximately 50.6GB
    echo "$0: downloading TEDLIUM_release-3 data (it won't re-download if it was already downloaded.)"
    # the following command won't re-get it if it's already there
    # because of the --continue switch.
    # if download fails, exit with code 1
    wget --continue http://www.openslr.org/resources/51/TEDLIUM_release-3.tgz || exit 1
    
    echo "$0: extracting TEDLIUM_release-3 data"
    # extract the archive to folder TEDLIUM_release-3
    tar xf "TEDLIUM_release-3.tgz"
  else
    echo "$0: not downloading or un-tarring TEDLIUM_release3 because it already exists."
  fi
fi

# find .sph files, wc -l will count the number of files found.
num_sph=$(find TEDLIUM_release-3/data -name '*.sph' | wc -l)
if [ "$num_sph" != 2351 ]; then
  echo "$0: expected to find 2351 .sph files in the directory db/TEDLIUM_release-3, found $num_sph"
  exit 1
fi

exit 0

