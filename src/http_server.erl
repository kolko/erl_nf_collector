-module(http_server).

-export([start_actor/1, http_loop/2]).


start_actor(NfCollectorPid) ->
    Pid = spawn(fun () -> start(NfCollectorPid) end),
    Pid.

start(NfCollectorPid) ->
    {ok, Sock} = gen_tcp:listen(8080, [{active, false}]),
    http_loop(NfCollectorPid, Sock).


http_loop(NfCollectorPid, Sock) ->
    {ok, Conn} = gen_tcp:accept(Sock),
    Handler = spawn(fun () -> http_handle(NfCollectorPid, Conn) end),
    gen_tcp:controlling_process(Conn, Handler),
    %% try to hot code reload work after ./rebar co
    try
        code:purge(?MODULE),
        code:load_file(?MODULE)
    catch _ -> ok end,
    ?MODULE:http_loop(NfCollectorPid, Sock).

http_handle(NfCollectorPid, Conn) ->
  NfCollectorPid ! {get_packages_lost_count, self()},
  {PackagesLostCount, _, PackagesReiceveCount} = receive
                        {packages_lost_count, {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}} ->
                          {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}
                      end,

  NfCollectorPid ! {get_abonents_speed, self()},
  AbonentsCount = receive
      {abonents_speed_count, AbonentsCountTmp} ->
        AbonentsCountTmp
    end,
  gen_tcp:send(Conn, response("<http><body><table id='myTable' class='tablesorter'>")),

  gen_tcp:send(Conn, write_more_data("<script type='text/javascript' src='http://tablesorter.com/jquery-latest.js'></script>")),
  gen_tcp:send(Conn, write_more_data("<script type='text/javascript' src='http://tablesorter.com/__jquery.tablesorter.min.js'></script> ")),
  gen_tcp:send(Conn, write_more_data("<script>$(document).ready(function(){$('#myTable').tablesorter();});</script>")),

  gen_tcp:send(Conn, write_more_data("<thead> <tr><th>1</th><th>2</th><th>3</th></tr></thead> <tbody> ")),
  gen_tcp:send(Conn, write_more_data(io_lib:format("<tr><td>count of abonents ~p </td><td></td><td></td></tr>", [AbonentsCount]))),
  gen_tcp:send(Conn, write_more_data(io_lib:format("<tr><td>packages_lost_count ~p reiceve: ~p</td><td></td><td></td></tr>", [PackagesLostCount, PackagesReiceveCount]))),
  receive_speed_list(Conn, AbonentsCount, 0.0, 0.0),
  gen_tcp:send(Conn, write_more_data("</tbody> </table></body></http>")),
  gen_tcp:close(Conn).

receive_speed_list(Conn, 0, TotalInput, TotalOutput) ->
  TotalString = io_lib:format("<tr><td>Total:</td><td>~.4f Kbit/sec</td><td>~.4f Kbit/sec</td></tr>", [TotalInput, TotalOutput]),
  gen_tcp:send(Conn, write_more_data(TotalString)),
  ok;

receive_speed_list(Conn, AbonentsCount, TotalInput, TotalOutput) ->
  receive
    {abonent_speed, Ip, Input, Output} ->
        NewTotalInput = TotalInput + (Input),
        NewTotalOutput = TotalOutput + (Output),
        SpeedString = io_lib:format("<tr><td>~p</td><td>~.4f Kbit/sec</td><td>~.4f Kbit/sec</td></tr>", [iplib:long2ip(Ip), Input, Output]),
        gen_tcp:send(Conn, write_more_data(SpeedString)),
        receive_speed_list(Conn, AbonentsCount-1, NewTotalInput, NewTotalOutput)
  end.


response(Str) ->
  B = iolist_to_binary(Str),
  io_lib:fwrite("HTTP/1.0 200 OK\nContent-Type: text/html\n\n~s", [B]).

write_more_data(Str) ->
  B = iolist_to_binary(Str),
  io_lib:fwrite("~s", [B]).