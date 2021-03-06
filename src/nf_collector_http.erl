-module(nf_collector_http).

-export([start_link/0, loop/1]).

start_link() ->
    {ok, Port} = application:get_env(http_web_port),
    {ok, Ip} = application:get_env(http_web_bind),
    mochiweb_http:start_link([{'ip', Ip}, {port, Port},
                       {'loop', fun ?MODULE:loop/1}]).

loop(Req) ->
    RawPath = Req:get(raw_path),
    {Path, _, _} = mochiweb_util:urlsplit_path(RawPath),

    case Path of
        "/" -> index_abon_list(Req);
        _    -> Req:respond({404, [{<<"Content-Type">>, <<"text/html">>}], <<"<p>Page not found!</p>">>})
    end.

index_abon_list(Req) ->
    {PackagesLostCount, _, PackagesReiceveCount} = nf_collector_flow:get_packages_lost_state(),

    nf_collector_flow:abonents_speed_request(self()),

    receive
        {abonents_speed_count, AbonentsCount} ->
            ok
    end,

    Resp = Req:respond({200, [{<<"Content-Type">>, <<"text/html">>}], chunked}),

    render_and_write_chunk(Resp, html_header_dtl, [
        {abonent_count, AbonentsCount},
        {packages_lost_count, PackagesLostCount},
        {packages_reiceve_count, PackagesReiceveCount}
    ]),

    receive_speed_list(Resp, AbonentsCount, 0.0, 0.0),

    render_and_write_chunk(Resp, html_footer_dtl, []),
    Resp:write_chunk(<<>>).

receive_speed_list(Resp, 0, TotalInput, TotalOutput) ->
    render_and_write_chunk(Resp, html_abonent_ceil_dtl, [
        {name, "Total"},
        {speed_in, TotalInput},
        {speed_out, TotalOutput}
    ]);

receive_speed_list(Resp, AbonentsCount, TotalInput, TotalOutput) ->
    receive
        {abonent_speed, Ip, Input, Output} ->
            NewTotalInput = TotalInput + Input,
            NewTotalOutput = TotalOutput + Output,

            render_and_write_chunk(Resp, html_abonent_ceil_dtl, [
                {name, iplib:long2ip(Ip)},
                {speed_in, Input},
                {speed_out, Output}
            ]),

            receive_speed_list(Resp, AbonentsCount-1, NewTotalInput, NewTotalOutput)
    end.

render_and_write_chunk(Resp, Template, Context) ->
    {ok, HTML} = Template:render(Context),
    Resp:write_chunk(HTML).