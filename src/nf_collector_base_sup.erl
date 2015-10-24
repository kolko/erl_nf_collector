-module(nf_collector_base_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(nf_collector_base_sup, []).

init(_Args) ->
    SupFlags = {one_for_one, 1, 5},
    ChildSpecs = [{nf_collector_http,
                        {nf_collector_http, start_link, []},
                        permanent,
                        brutal_kill,
                        worker,
                        [nf_collector_http]},

                    {nf_collector_flow_sup,
                        {nf_collector_flow_sup, start_link, []},
                        permanent,
                        brutal_kill,
                        supervisor,
                        [nf_collector_flow_sup]}
                    ],
    {ok, {SupFlags, ChildSpecs}}.