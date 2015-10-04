#!/bin/sh

erl -noshell \
    -pa ebin ./deps/*/ebin \
    -s lager \
    -s main start