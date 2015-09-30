-module(main).

%% API
-export([start/0]).

-define(INFO_MSG(Format, Args), error_logger:info_msg(Format, Args)).
-define(WARNING_MSG(Format, Args), error_logger:warning_msg(Format, Args)).
-define(ERROR_MSG(Format, Args), error_logger:error_msg(Format, Args)).

-include("netflow_v5.hrl").

-record(state, {socket, port, handlers = []}).


start() ->
  {ok, SocketOptions} = make_sock_options(),
  {ok, Socket} = open_socket(SocketOptions),
  AbonIpDict = dict:new(),
  Pid = self(),
  spawn(fun () -> start_http_server(Pid) end),
  main_loop(Socket, AbonIpDict, {0, -1, 0}).

make_sock_options() ->
  StrIP = "0.0.0.0",
  Port = 9996,
  {ok, IP} = inet_parse:address(StrIP),
  Family = inet,
  SocketOpts = [binary, Family, {ip, IP}, {active, true}, {reuseaddr, true}],
  {ok, {StrIP, Port, SocketOpts}}.

open_socket({StrIP, Port, SocketOpts}) ->
  case gen_udp:open(Port, SocketOpts) of
    {ok, Socket} ->
      ?INFO_MSG("Starting netflow service on ~s:~p~n", [StrIP, Port]),
      {ok, Socket};
    {error, Reason} ->
      {stop, Reason}
  end.

main_loop(Socket, AbonIpDict, LostState) ->
  receive
    {udp, Socket, Host, Port, Bin} ->
%%       ?INFO_MSG("server received package ~n", []),
      {ok, {Header, FlowList}} = parse_package(Bin, Host),
      NewAbonIpDict = process_package(AbonIpDict, Header, FlowList),
      NewLostState = calc_lost(LostState, Header),
      main_loop(Socket, NewAbonIpDict, NewLostState);
    {get_abonents_speed, HttpPid} ->
      HttpPid ! {abonents_speed_count, dict:size(AbonIpDict)},
      dict:map(
        fun(_, [V]) ->
          V ! {send_speed, HttpPid} end,
        AbonIpDict),
      main_loop(Socket, AbonIpDict, LostState);
    {get_packages_lost_count, HttpPid} ->
      HttpPid ! {packages_lost_count, LostState},
      main_loop(Socket, AbonIpDict, LostState);
    Unknown ->
      ?ERROR_MSG("ERROR! ~p~n", [Unknown]),
      main_loop(Socket, AbonIpDict, LostState)
  end.

calc_lost(LostState={Count, LastFlowSeq, ReiceveCount}, Header) ->
  if
    LastFlowSeq == -1 ->
      %% еще не было пакетов
      {Count, Header#nfh_v5.flow_seq + Header#nfh_v5.count, ReiceveCount + Header#nfh_v5.count};
    LastFlowSeq ==  Header#nfh_v5.flow_seq ->
      %% все в норме, идем по порядку
      {Count, Header#nfh_v5.flow_seq + Header#nfh_v5.count, ReiceveCount + Header#nfh_v5.count};
    LastFlowSeq < Header#nfh_v5.flow_seq ->
      %% пропустили пакеты
      {Count + (Header#nfh_v5.flow_seq - LastFlowSeq), Header#nfh_v5.flow_seq + Header#nfh_v5.count, ReiceveCount + Header#nfh_v5.count};
    LastFlowSeq > Header#nfh_v5.flow_seq ->
      %% пришли пакеты, которые мы ранее пропускали (udp не гарантирует порядок)
      {Count - Header#nfh_v5.count, LastFlowSeq, ReiceveCount + Header#nfh_v5.count}
  end.

parse_package(<<9:16, _/binary>> = Packet, IP) ->
  ?ERROR_MSG("NF v9 is not working~n", []);
%%   netflow_v9:decode(Packet, IP);
parse_package(<<5:16, _/binary>> = Packet, _) ->
  netflow_v5:decode(Packet);
%% {{nfh_v5,5,30,78619134,1436346095,520667000,3137309336,0,0,0},
%% [{nfrec_v5,3645213672,93156823,176163281,0,50277,2,80,
%% 78613844,78613844,80,50475,17,6,0,0,0,0,0},
%% {nfrec_v5,176161848,3132099565,93120513,0,3,2,340,78613844,
%% 78613844,49001,21011,0,17,0,0,0,0,0},
%% {nfrec_v5,176162980,1475380980,93120513,0,3,5,2336,
%% 78613854,78613854,50005,80,2,6,0,0,0,0,0},
%% {nfrec_v5,781369251,93156834,176161926,0,28624,2,98,
%% 78613854,78613854,43154,49753,24,6,32,0,0,0,0},
%% {nfrec_v5,176162980,3274055683,93120513,0,3,2,120,78613854,
%% 78613854,55614,53,0,17,0,0,0,0,0},
%% {nfrec_v5,176163040,1500582184,93120513,0,3,3,180,78610774,
%% 78613854,45476,18090,2,6,0,0,0,0,0},

parse_package(_, _) ->
  {error, unknown_packet}.


process_package(AbonIpDict, Header, [FlowItem | FlowList]) ->
  NetMask = "10.128.0.0/16",
  case iplib:in_range(iplib:long2ip(FlowItem#nfrec_v5.src_addr), NetMask) of
    true ->
      AbonIpDict2 = send_or_create_to_abonent_actor(AbonIpDict, FlowItem#nfrec_v5.src_addr, FlowItem);
    false ->
      AbonIpDict2 = AbonIpDict
  end,
  case iplib:in_range(iplib:long2ip(FlowItem#nfrec_v5.dst_addr), NetMask) of
    true ->
      AbonIpDict3 = send_or_create_to_abonent_actor(AbonIpDict2, FlowItem#nfrec_v5.dst_addr, FlowItem);
    false ->
      AbonIpDict3 = AbonIpDict2
  end,
  process_package(AbonIpDict3, Header, FlowList);

process_package(AbonIpDict, _, []) ->
  AbonIpDict.

send_or_create_to_abonent_actor(AbonIpDict, Ip, FlowItem) ->
%%   ?INFO_MSG("Process package for ~p dict: ~p ~n", [iplib:long2ip(Ip), AbonIpDict]),
  case dict:find(Ip, AbonIpDict) of
    {ok, [Pid]} ->
%%       ?INFO_MSG(",, ~p ~n", [process_info(Pid)]),
      Pid ! {flow, FlowItem},
      AbonIpDict;
    error ->
%%       ?INFO_MSG("Spawn new!! For ~p ~n", [iplib:long2ip(Ip)]),
%%       ?INFO_MSG("Size of dict: ~p process count: ~p ~n", [dict:size(AbonIpDict), length(erlang:processes())]),
      Pid = spawn(fun() -> abonent_actor(Ip, orddict:new(), orddict:new()) end),
      Pid ! {flow, FlowItem},
      NewAbonIpDict = dict:append(Ip, Pid, AbonIpDict),
      NewAbonIpDict
  end.

abonent_actor(Ip, InputSpeedList, OutputSpeedList) ->
  receive
    {flow, Package} ->
%%       ?INFO_MSG("Flow data ~n", []),
      if
        Ip == Package#nfrec_v5.src_addr ->
          NewOutputSpeedList = add_speed(OutputSpeedList, Package),
          abonent_actor(Ip, InputSpeedList, NewOutputSpeedList);
        Ip == Package#nfrec_v5.dst_addr ->
          NewInputSpeedList = add_speed(InputSpeedList, Package),
          abonent_actor(Ip, NewInputSpeedList, OutputSpeedList);
        true ->
          ?ERROR_MSG("ERROR!!!!!!!! ~n", []),
          abonent_actor(Ip, InputSpeedList, OutputSpeedList)
      end;
    {send_speed, HttpPid} ->
      MaxInput = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, InputSpeedList),
      MaxOutput = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, OutputSpeedList),
      HttpPid ! {abonent_speed, Ip, MaxInput, MaxOutput},
      abonent_actor(Ip, InputSpeedList, OutputSpeedList);
    Unknown ->
      ?ERROR_MSG("ERROR in abonent_actor! ~p~n", [Unknown]),
      abonent_actor(Ip, InputSpeedList, OutputSpeedList)
  end.

add_speed(SpeedList, Package) ->
  FirstTime = Package#nfrec_v5.first div 1000,
  LastTime = Package#nfrec_v5.last div 1000,

%%   ?INFO_MSG("~p ~p ~p ~n", [LastTime - FirstTime, FirstTime, LastTime]),
  AvgTraff = Package#nfrec_v5.d_octets * 8.0 / 1000.0 / ((LastTime - FirstTime )+ 1.0),
  NewSpeedList = update_or_append_counters(SpeedList, AvgTraff, LastTime, (LastTime - FirstTime) + 1),
  NewSpeedList2 = clear_old_counters(NewSpeedList),
  NewSpeedList2.


update_or_append_counters(SpeedList, _, _, Count) when Count =< 0 ->
  SpeedList;

update_or_append_counters(SpeedList, AvgTraff, From, Count) when Count > 300 ->
  ?ERROR_MSG("Big aggregation! ~p ~n", [Count]),
  update_or_append_counters(SpeedList, AvgTraff, From + (Count - 300), 300);

update_or_append_counters(SpeedList, AvgTraff, From, Count) ->
  NewSpeedList = orddict:update_counter(From, AvgTraff, SpeedList),
  update_or_append_counters(NewSpeedList, AvgTraff, From+1, Count-1).

clear_old_counters(SpeedList) ->
  MaxTime = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Key, AccIn]) end, 0, SpeedList),
  MinTime = orddict:fold(fun(Key, Value, AccIn) -> lists:min([Key, AccIn]) end, MaxTime, SpeedList),
%%   ?INFO_MSG("In erase! Max: ~p Min: ~p ~n", [MaxTime, MinTime]),
  if
    MaxTime - MinTime > 300 ->
      NewSpeedList = orddict:erase(MinTime, SpeedList),
%%       ?INFO_MSG("In erase! Erase: ~p ~n", [MinTime]),
      clear_old_counters(NewSpeedList);
    true ->
      SpeedList
  end.






%%% HTTP %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start_http_server(ParentPid) ->
  {ok, Sock} = gen_tcp:listen(8080, [{active, false}]),
  http_loop(ParentPid, Sock).

http_loop(ParentPid, Sock) ->
  {ok, Conn} = gen_tcp:accept(Sock),
  Handler = spawn(fun () -> http_handle(ParentPid, Conn) end),
  gen_tcp:controlling_process(Conn, Handler),
  http_loop(ParentPid, Sock).

http_handle(ParentPid, Conn) ->
  ParentPid ! {get_packages_lost_count, self()},
  {PackagesLostCount, _, PackagesReiceveCount} = receive
                        {packages_lost_count, {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}} ->
                          {CountTmp, LastFlowSeqTmp, ReiceveCountTmp}
                      end,

  ParentPid ! {get_abonents_speed, self()},
  AbonentsCount = receive
      {abonents_speed_count, AbonentsCountTmp} ->
        ?INFO_MSG("Get abonents_speed_count ~p ~n", [AbonentsCountTmp]),
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
%%   ?INFO_MSG("4.2 ~p~n", [AbonentsCount]),
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
  iolist_to_binary(
%%     io_lib:fwrite(
%%       "HTTP/1.0 200 OK\nContent-Type: text/html\nContent-Length: ~p\n\n~s",
%%       [size(B), B])).
    io_lib:fwrite(
      "HTTP/1.0 200 OK\nContent-Type: text/html\n\n~s",
      [B])).

write_more_data(Str) ->
  B = iolist_to_binary(Str),
  iolist_to_binary(
    io_lib:fwrite(
      "~s",
      [B])).