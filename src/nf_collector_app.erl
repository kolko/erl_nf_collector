-module(nf_collector_app).

-export([start/0]).

start() ->
    nf_collector:start_link(),
    http_server:start_actor(),
    receive
        {_} ->
            io:format("boop")
    end.