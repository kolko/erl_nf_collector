#!/bin/sh

erl -noshell \
    -pa ebin ./deps/*/ebin \
    -s lager \
    -s nf_collector_app start