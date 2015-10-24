-module(nf_collector).
-behaviour(application).
-export([start/2, stop/1]).

start(normal, _Args) ->
    nf_collector_base_sup:start_link().

stop(_State) ->
    ok.