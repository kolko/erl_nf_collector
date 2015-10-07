-module(http_server).

-export([start_actor/0, loop/1]).

start_actor() ->
  mochiweb_http:start([{'ip', "127.0.0.1"}, {port, 8080},
                       {'loop', fun ?MODULE:loop/1}]).

loop(Req) ->
  RawPath = Req:get(raw_path),
  {Path, _, _} = mochiweb_util:urlsplit_path(RawPath),   % get request path

  case Path of                                           % respond based on path
    "/" -> index_abon_list(Req);
    _    -> respond(Req, <<"<p>Page not found!</p>">>)
  end.

respond(Req, Content) ->
  Req:respond({200, [{<<"Content-Type">>, <<"text/html">>}], Content}).


index_abon_list(Req) ->
  nf_collector ! {get_packages_lost_count, self()},
  {PackagesLostCount, _, PackagesReiceveCount} = receive
                        {packages_lost_count, {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}} ->
                          {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}
                      end,

  nf_collector ! {get_abonents_speed, self()},
  AbonentsCount = receive
      {abonents_speed_count, AbonentsCountTmp} ->
        AbonentsCountTmp
    end,
  Resp = Req:respond({200, [{<<"Content-Type">>, <<"text/html">>}], chunked}),
  Resp:write_chunk(<<"<http><body><table id='myTable' class='tablesorter'>">>),

  Resp:write_chunk(<<"<script type='text/javascript' src='http://tablesorter.com/jquery-latest.js'></script>">>),
  Resp:write_chunk(<<"<script type='text/javascript' src='http://tablesorter.com/__jquery.tablesorter.min.js'></script> ">>),
  Resp:write_chunk(<<"<script>$(document).ready(function(){$('#myTable').tablesorter();});</script>">>),

  Resp:write_chunk(<<"<thead> <tr><th>1</th><th>2</th><th>3</th></tr></thead> <tbody> ">>),
  Resp:write_chunk(io_lib:format("<tr><td>count of abonents ~p </td><td></td><td></td></tr>", [AbonentsCount])),
  Resp:write_chunk(io_lib:format("<tr><td>packages_lost_count ~p reiceve: ~p</td><td></td><td></td></tr>", [PackagesLostCount, PackagesReiceveCount])),
  receive_speed_list(Resp, AbonentsCount, 0.0, 0.0),
  Resp:write_chunk(<<"</tbody> </table></body></http>">>),
  Resp:write_chunk(<<>>).

receive_speed_list(Resp, 0, TotalInput, TotalOutput) ->
  Resp:write_chunk(io_lib:format("<tr><td>Total:</td><td>~.4f Kbit/sec</td><td>~.4f Kbit/sec</td></tr>", [TotalInput, TotalOutput]));

receive_speed_list(Resp, AbonentsCount, TotalInput, TotalOutput) ->
  receive
    {abonent_speed, Ip, Input, Output} ->
        NewTotalInput = TotalInput + (Input),
        NewTotalOutput = TotalOutput + (Output),
        Resp:write_chunk(io_lib:format("<tr><td>~p</td><td>~.4f Kbit/sec</td><td>~.4f Kbit/sec</td></tr>", [iplib:long2ip(Ip), Input, Output])),
        receive_speed_list(Resp, AbonentsCount-1, NewTotalInput, NewTotalOutput)
  end.
