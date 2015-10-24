-module(nf_collector_flow_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(nf_collector_flow_sup, []).

init(_Args) ->
    SupFlags = {one_for_one, 1, 6},
    ChildSpecs = [{nf_collector_flow,
                        {nf_collector_flow, start_link, []},
                        permanent,
                        brutal_kill,
                        worker,
                        [nf_collector_flow]}
                    ],
    {ok, {SupFlags, ChildSpecs}}.