#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable -sname factorial -mnesia debug verbose

-export([main/1]).

main(_) ->
    compile:file("main"),
    compile:file("netflow_v5"),
    compile:file("iplib"),
    main:start().