-module(nf_collector_calc_top).

-export([start_abon_actor/1]).

start_abon_actor(Ip) ->
    spawn(fun () -> loop(Ip) end).

loop(Ip) ->
  loop(Ip).