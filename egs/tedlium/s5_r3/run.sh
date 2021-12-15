#!/usr/bin/env bash
#
# Based mostly on the Switchboard recipe. The training database is TED-LIUM,
# it consists of TED talks with cleaned automatic transcripts:
#
# https://lium.univ-lemans.fr/ted-lium3/
# http://www.openslr.org/resources (Mirror).
#
# The data is distributed under 'Creative Commons BY-NC-ND 3.0' license,
# which allow free non-commercial use, while only a citation is required.
#
# Copyright  2014  Nickolay V. Shmyrev
#            2014  Brno University of Technology (Author: Karel Vesely)
#            2016  Vincent Nguyen
#            2016  Johns Hopkins University (Author: Daniel Povey)
#            2018  François Hernandez
#
# Apache 2.0
#

# step 0.a
echo "step 0.a....."
# set the running environment: locally or cluster
. ./cmd.sh
# add openfst, sph2pipe, kaldi root and src bin directories to path
. ./path.sh

# step 0.b
echo "step 0.b....."
# set -e: if a simple command fails for some reasons, the shell shall immediately exit. see: https://linuxcommand.org/lc3_man_pages/seth.html 
# set -o pipefail: Pipelines fail on the first command which fails instead of dying later on down the pipeline.
# set -u: The shell prints a message to stderr when it tries to expand a variable that is not set.
set -e -o pipefail -u

# step 0.c
echo "step 0.c....."
nj=35
decode_nj=38   # note: should not be >38 which is the number of speakers in the dev set
               # after applying --seconds-per-spk-max 180.  We decode with 4 threads, so
               # this will be too many jobs if you're using run.pl.

# stage: you can start from the stage you stopped last time
stage=0
train_rnnlm=false
train_lm=false

. utils/parse_options.sh # accept options

# step 0.d Data preparation
echo "step 0.d....."
# download and extract the data (approximately 54 GB) from http://www.openslr.org/resources/51/TEDLIUM_release-3.tgz
# it should contain 2351 .sph files
# if stage is less or equal to 0
if [ $stage -le 0 ]; then
  local/download_data.sh
fi

# step 1
echo "step 1....."
if [ $stage -le 1 ]; then
  # prepare dev, train and test datasets
  local/prepare_data.sh
  # Split speakers up into 3-minute chunks.  This doesn't hurt adaptation, and
  # lets us use more jobs for decoding etc.
  # [we chose 3 minutes because that gives us 38 speakers for the dev data, which is
  #  more than our normal 30 jobs.]
  for dset in dev test train; do
    utils/data/modify_speaker_info.sh --seconds-per-spk-max 180 data/${dset}.orig data/${dset}
  done
fi

# step 2
echo "step 2....."
# prepare lexicon.txt, nonsilence_phones.txt and silence_phones.txt
if [ $stage -le 2 ]; then
  local/prepare_dict.sh
fi

# step 3
echo "step 3....."
# prepare language diretory data/lang_nosp
# syntax: utils/prepare_lang.sh <dict-src-dir> <oov-dict-entry> <tmp-dir> <lang-dir>
if [ $stage -le 3 ]; then
  utils/prepare_lang.sh data/local/dict_nosp \
    "<unk>" data/local/lang_nosp data/lang_nosp
fi

# step 4
echo "step 4....."
# train n-gram language model
if [ $stage -le 4 ]; then
  # later on we'll change this script so you have the option to
  # download the pre-built LMs from openslr.org instead of building them
  # locally.
  if $train_lm; then
    local/ted_train_lm.sh
  else
    local/ted_download_lm.sh
  fi
fi

# step 5
echo "step 5....."
# convert 4-gram ARPA model to FST model
if [ $stage -le 5 ]; then
  local/format_lms.sh
fi

# step 6
echo "step 6....."
# Extract MFCC features and normalize with CMVN
# Feature extraction
if [ $stage -le 6 ]; then
  for set in test dev train; do
    dir=data/$set
    steps/make_mfcc.sh --nj 30 --cmd "$train_cmd" $dir
    steps/compute_cmvn_stats.sh $dir
  done
fi

# step 7
echo "step 7....."
# split the training data to shorter segments
# Now we have 452 hours of training data.
# Well create a subset with 10k short segments to make flat-start training easier:
if [ $stage -le 7 ]; then
  utils/subset_data_dir.sh --shortest data/train 10000 data/train_10kshort
  utils/data/remove_dup_utts.sh 10 data/train_10kshort data/train_10kshort_nodup
fi

# step 8
echo "step 8....."
# Train monophone model
if [ $stage -le 8 ]; then
  steps/train_mono.sh --nj 20 --cmd "$train_cmd" \
    data/train_10kshort_nodup data/lang_nosp exp/mono
fi

# step 9
echo "step 9....."
# align the data and train tri1 model
# steps/train_deltas.sh <num-leaves> <tot-gauss> <data-dir> <lang-dir> <alignment-dir> <exp-dir>
if [ $stage -le 9 ]; then
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/train data/lang_nosp exp/mono exp/mono_ali
  steps/train_deltas.sh --cmd "$train_cmd" \
    2500 30000 data/train data/lang_nosp exp/mono_ali exp/tri1
fi

# step 10
echo "step 10....."
# create an HCLG decoding graph, check 
# Usage: utils/mkgraph.sh [options] <lang-dir> <model-dir><graphdir>
# and decode
# Usage: steps/decode.sh [options] <graph-dir> <data-dir> <decode-dir>"
if [ $stage -le 10 ]; then
  utils/mkgraph.sh data/lang_nosp exp/tri1 exp/tri1/graph_nosp

  # The slowest part about this decoding is the scoring, which we can't really
  # control as the bottleneck is the NIST tools.
  for dset in dev test; do
    steps/decode.sh --nj $decode_nj --cmd "$decode_cmd"  --num-threads 4 \
      exp/tri1/graph_nosp data/${dset} exp/tri1/decode_nosp_${dset}
    steps/lmrescore_const_arpa.sh  --cmd "$decode_cmd" data/lang_nosp data/lang_nosp_rescore \
       data/${dset} exp/tri1/decode_nosp_${dset} exp/tri1/decode_nosp_${dset}_rescore
  done
fi

# step 11
echo "step 11....."
# align the data, reduce dimensions by LDA(Linear Discriminant Analysis) and 
# then apply MLLT(Maximum Likelihood Linear Transform)
if [ $stage -le 11 ]; then
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/train data/lang_nosp exp/tri1 exp/tri1_ali

  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    4000 50000 data/train data/lang_nosp exp/tri1_ali exp/tri2
fi

# step 12
echo "step 12....."
# create decoding graph and decode
if [ $stage -le 12 ]; then
  utils/mkgraph.sh data/lang_nosp exp/tri2 exp/tri2/graph_nosp
  for dset in dev test; do
    steps/decode.sh --nj $decode_nj --cmd "$decode_cmd"  --num-threads 4 \
      exp/tri2/graph_nosp data/${dset} exp/tri2/decode_nosp_${dset}
    steps/lmrescore_const_arpa.sh  --cmd "$decode_cmd" data/lang_nosp data/lang_nosp_rescore \
       data/${dset} exp/tri2/decode_nosp_${dset} exp/tri2/decode_nosp_${dset}_rescore
  done
fi

# step 13
echo "step 13....."
# steps/get_prons.sh create counts of pronunciations from training data
# utils/dict_dir_add_pronprobs.sh Take the pronunciation counts and create a modified dictionary directory with pronunciation probabilities.
# usage: [options] <input-dict-dir> <input-pron-counts>[input-sil-counts] [input-bigram-counts] <output-dict-dir>
if [ $stage -le 13 ]; then
  steps/get_prons.sh --cmd "$train_cmd" data/train data/lang_nosp exp/tri2
  utils/dict_dir_add_pronprobs.sh --max-normalize true \
    data/local/dict_nosp exp/tri2/pron_counts_nowb.txt \
    exp/tri2/sil_counts_nowb.txt \
    exp/tri2/pron_bigram_counts_nowb.txt data/local/dict
fi

# step 14
echo "step 14....."
# create decoding graph and decode
if [ $stage -le 14 ]; then
  utils/prepare_lang.sh data/local/dict "<unk>" data/local/lang data/lang
  cp -rT data/lang data/lang_rescore
  cp data/lang_nosp/G.fst data/lang/
  cp data/lang_nosp_rescore/G.carpa data/lang_rescore/

  utils/mkgraph.sh data/lang exp/tri2 exp/tri2/graph

  for dset in dev test; do
    steps/decode.sh --nj $decode_nj --cmd "$decode_cmd"  --num-threads 4 \
      exp/tri2/graph data/${dset} exp/tri2/decode_${dset}
    steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
       data/${dset} exp/tri2/decode_${dset} exp/tri2/decode_${dset}_rescore
  done
fi

# step 15
echo "step 15....."
# Train a triphone model with Speaker Adaptation Training
# Usage: steps/train_sat.sh <#leaves> <#gauss> <data> <lang> <ali-dir> <exp-dir>
# create decoding graph and decode
if [ $stage -le 15 ]; then
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/train data/lang exp/tri2 exp/tri2_ali

  steps/train_sat.sh --cmd "$train_cmd" \
    5000 100000 data/train data/lang exp/tri2_ali exp/tri3

  utils/mkgraph.sh data/lang exp/tri3 exp/tri3/graph

  for dset in dev test; do
    steps/decode_fmllr.sh --nj $decode_nj --cmd "$decode_cmd"  --num-threads 4 \
      exp/tri3/graph data/${dset} exp/tri3/decode_${dset}
    steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
       data/${dset} exp/tri3/decode_${dset} exp/tri3/decode_${dset}_rescore
  done
fi

# step 16
#echo "step 16....."
# re-segment training data selecting only the "good" audio that matches the transcripts
#if [ $stage -le 16 ]; then
  # this does some data-cleaning.  It actually degrades the GMM-level results
  # slightly, but the cleaned data should be useful when we add the neural net and chain
  # systems.  If not we'll remove this stage.
  #local/run_cleanup_segmentation.sh
#fi

# step 17
#echo "step 17....."
# apply Time delay neural network (TDNN) with GPUs
#if [ $stage -le 17 ]; then
  # This will only work if you have GPUs on your system (and note that it requires
  # you to have the queue set up the right way... see kaldi-asr.org/doc/queue.html)
  #local/chain/run_tdnn.sh
#fi

# step 18
#echo "step 18....."
# train rnnlm models
#if [ $stage -le 18 ]; then
  # You can either train your own rnnlm or download a pre-trained one
  #if $train_rnnlm; then
    #local/rnnlm/tuning/run_lstm_tdnn_a.sh
    #local/rnnlm/average_rnnlm.sh
  #else
    #local/ted_download_rnnlm.sh
  #fi
#fi

# step 19
#echo "step 19....."
# the final decode step
# rnnlm/lmrescore_pruned.sh rescores lattices with KALDI RNNLM using a pruned algorithm
#if [ $stage -le 19 ]; then
  # Here we rescore the lattices generated at stage 17
  #rnnlm_dir=exp/rnnlm_lstm_tdnn_a_averaged
  #lang_dir=data/lang_chain
  #ngram_order=4

  #for dset in dev test; do
    #data_dir=data/${dset}_hires
    #decoding_dir=exp/chain_cleaned/tdnnf_1a/decode_${dset}
    #suffix=$(basename $rnnlm_dir)
    #output_dir=${decoding_dir}_$suffix

    #rnnlm/lmrescore_pruned.sh \
      #--cmd "$decode_cmd --mem 4G" \
      #--weight 0.5 --max-ngram-order $ngram_order \
      #$lang_dir $rnnlm_dir \
      #$data_dir $decoding_dir \
      #$output_dir
  #done
#fi


echo "$0: success."
exit 0

# References:
# https://kaldi-asr.org/doc/graph.html
# https://medium.com/swlh/automatic-speech-recognition-system-using-kaldi-from-scratch-337eb7c8eea8
# http://www.danielpovey.com/files/2018_icassp_lattice_pruning.pdf
