#!/bin/sh

erl -noshell \
    -pa ebin ./deps/*/ebin \
    -s lager \
    -eval "application:start(nf_collector)"  #-s nf_collector