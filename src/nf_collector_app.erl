-module(nf_collector_app).

-export([start/0]).

start() ->
    NfCollectorPid = nf_collector:start_actor(),
    http_server:start_actor(NfCollectorPid),
    receive
        {_} ->
            io:format("boop")
    end.