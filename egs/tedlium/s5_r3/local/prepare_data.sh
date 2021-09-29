#!/usr/bin/env bash
#
# Copyright  2014  Nickolay V. Shmyrev
#            2014  Brno University of Technology (Author: Karel Vesely)
#            2016  Johns Hopkins University (Author: Daniel Povey)
#            2018  François Hernandez
#
# Apache 2.0

# For more information about data preparation, visit http://kaldi-asr.org/doc/data_prep.html
# Here are some important files' description.

# The output of the data preparation stage consists of two sets of things. 
# One relates to "the data" (directories like data/train/) and one relates to "the language" (directories like data/lang/). 
# The "data" part relates to the specific recordings you have, 
# and the "lang" part contains things that relate more to the language itself, such as the lexicon, the phone set, 
# and various extra information about the phone set that Kaldi needs. 

# The first file you need to prepare is "text" which contains the transcriptions of each utterance.
# The first element on each line is the utterance-id, if you have speaker information in your setup, you should make the speaker-id a prefix of the utterance id
# The rest of the line is the transcription of each sentence. Format:
# <utterance-id> <sentence>
# e.g. sw02001-A_000098-001156 HI UM YEAH I'D LIKE TO TALK ABOUT

# The format of "wav.scp" file is
# <recording-id> <extended-filename>
# where the "extended-filename" may be an actual filename, or a command that extracts a wav-format file.

# The format of the "segments" file is:
# <utterance-id> <recording-id> <segment-begin> <segment-end>
# where the segment-begin and segment-end are measured in seconds. 
# These specify time offsets into a recording. The "recording-id" is the same identifier as is used in the "wav.scp" file

# The file "reco2file_and_channel" is only used when scoring (measuring error rates) with NIST's "sclite" tooly. The format is::
# <recording-id> <filename> <recording-side (A or B)>
# e.g. sw02001-B sw02001 B
# The recording side is a concept that relates to telephone conversations where there are two channels, and if not, it's probably safe to use "A".

# The last file you need to create yourself is the "utt2spk" file. The format is
# <utterance-id> <speaker-id>
# e.g. sw02001-A_000098-001156 2001-A

# The other files in this directory can be generated from the files you provide.
# the format of the spk2utt file is <speaker-id> <utterance-id1> <utterance-id2> ....
# You can create the "spk2utt" file by a command like:
# utils/utt2spk_to_spk2utt.pl data/train/utt2spk > data/train/spk2utt

# sclite is a tool to score speech recognition system output, check https://github.com/usnistgov/SCTK/blob/master/doc/sclite.htm

# in this data, recording-id = filename = speaker-id

# To be run from one directory above this script.

. ./path.sh

# Prepare: dev, test, train,
for set in dev test train; do
  dir=data/$set.orig
  mkdir -p $dir

  # Merge transcripts into a single 'stm' file, do some mappings:
  # - <F0_M> -> <o,f0,male> : map dev stm labels to be coherent with train + test,
  # - <F0_F> -> <o,f0,female> : --||--
  # - (2) -> null : remove pronunciation variants in transcripts, keep in dictionary
  # - <sil> -> null : remove marked <sil>, it is modelled implicitly (in kaldi)
  # - (...) -> null : remove utterance names from end-lines of train
  # - it 's -> it's : merge words that contain apostrophe (if compound in dictionary, local/join_suffix.py)
  { # Add STM header, so sclite can prepare the '.lur' file
    echo ';;
;; LABEL "o" "Overall" "Overall results"
;; LABEL "f0" "f0" "Wideband channel"
;; LABEL "f2" "f2" "Telephone channel"
;; LABEL "male" "Male" "Male Talkers"
;; LABEL "female" "Female" "Female Talkers"
;;'
    # Process the STMs
    # list lines of stm files and sort them by joint numerical keys: (1，2，4) columns
    cat db/TEDLIUM_release-3/legacy/$set/stm/*.stm | sort -k1,1 -k2,2 -k4,4n | \
      sed -e 's:([^ ]*)$::' | \
      awk '{ $2 = "A"; print $0; }'
  } | local/join_suffix.py > data/$set.orig/stm

  # Prepare 'text' file
  # - {NOISE} -> [NOISE] : map the tags to match symbols in dictionary
  cat $dir/stm | grep -v -e 'ignore_time_segment_in_scoring' -e ';;' | \
    awk '{ printf ("%s-%07d-%07d", $1, $4*100, $5*100);
           for (i=7;i<=NF;i++) { printf(" %s", $i); }
           printf("\n");
         }' | tr '{}' '[]' | sort -k1,1 > $dir/text || exit 1

  # Prepare 'segments', 'utt2spk', 'spk2utt'
  cat $dir/text | cut -d" " -f 1 | awk -F"-" '{printf("%s %s %07.2f %07.2f\n", $0, $1, $2/100.0, $3/100.0)}' > $dir/segments
  cat $dir/segments | awk '{print $1, $2}' > $dir/utt2spk
  cat $dir/utt2spk | utils/utt2spk_to_spk2utt.pl > $dir/spk2utt

  # Prepare 'wav.scp', 'reco2file_and_channel'
  cat $dir/spk2utt | awk -v set=$set -v pwd=$PWD '{ printf("%s sph2pipe -f wav -p %s/db/TEDLIUM_release-3/legacy/%s/sph/%s.sph |\n", $1, pwd, set, $1); }' > $dir/wav.scp
  cat $dir/wav.scp | awk '{ print $1, $1, "A"; }' > $dir/reco2file_and_channel

  # Create empty 'glm' file
  echo ';; empty.glm
  [FAKE]     =>  %HESITATION     / [ ] __ [ ] ;; hesitation token
  ' > data/$set.orig/glm

  # The training set seems to not have enough silence padding in the segmentations,
  # especially at the beginning of segments.  Extend the times.
  if [ $set == "train" ]; then
    mv data/$set.orig/segments data/$set.orig/segments.temp
    utils/data/extend_segment_times.py --start-padding=0.15 \
      --end-padding=0.1 <data/$set.orig/segments.temp >data/$set.orig/segments || exit 1
    rm data/$set.orig/segments.temp
  fi

  # Check that data dirs are okay!
  utils/validate_data_dir.sh --no-feats $dir || exit 1
done

