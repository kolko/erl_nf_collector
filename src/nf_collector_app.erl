-module(nf_collector_app).

-export([start/0]).

start() ->
    NfCollectorPid = nf_collector:start_actor(),
    register(nf_collector, NfCollectorPid),
    http_server:start_actor(),
    receive
        {_} ->
            io:format("boop")
    end.