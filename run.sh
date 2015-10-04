#!/usr/bin/env escript -n
%% -*- erlang -*-
%%! -smp enable -sname erl_nf_collector -pa ./deps/goldrush/ebin -pa ./deps/lager/ebin -pa ./src/ -s lager

-export([main/1]).

-compile([{parse_transform, lager_transform}]).

main(_) ->
    compile:file("main"),
    compile:file("http_server"),
    compile:file("netflow_v5"),
    compile:file("iplib"),
    MainloopPid = main:start_actor(),
    http_server:start_http_server_actor(MainloopPid),
    receive
        {_} ->
            io:format("boop")
    end.
