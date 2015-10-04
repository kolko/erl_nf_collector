-module(main).

-export([start/0, start_actor/0]).

-include("netflow_v5.hrl").
-record(state, {socket, port, handlers = []}).

start_actor() ->
    Pid = spawn(fun () -> start() end),
    Pid.

start() ->
  {ok, SocketOptions} = make_sock_options(),
  {ok, Socket} = open_socket(SocketOptions),
  AbonIpDict = dict:new(),
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
      lager:info("Starting netflow service on ~s:~p~n", [StrIP, Port]),
      {ok, Socket};
    {error, Reason} ->
      {stop, Reason}
  end.

main_loop(Socket, AbonIpDict, LostState) ->
  receive
    {udp, Socket, Host, Port, Bin} ->
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
      lager:info("ERROR! ~p~n", [Unknown]),
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
  lager:info("NF v9 is not working~n", []);
%%   netflow_v9:decode(Packet, IP);
parse_package(<<5:16, _/binary>> = Packet, _) ->
  netflow_v5:decode(Packet);

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
  case dict:find(Ip, AbonIpDict) of
    {ok, [Pid]} ->
      Pid ! {flow, FlowItem},
      AbonIpDict;
    error ->
      Pid = spawn(fun() -> abonent_actor(Ip, orddict:new(), orddict:new()) end),
      Pid ! {flow, FlowItem},
      NewAbonIpDict = dict:append(Ip, Pid, AbonIpDict),
      NewAbonIpDict
  end.

abonent_actor(Ip, InputSpeedList, OutputSpeedList) ->
  receive
    {flow, Package} ->
      if
        Ip == Package#nfrec_v5.src_addr ->
          NewOutputSpeedList = add_speed(OutputSpeedList, Package),
          abonent_actor(Ip, InputSpeedList, NewOutputSpeedList);
        Ip == Package#nfrec_v5.dst_addr ->
          NewInputSpeedList = add_speed(InputSpeedList, Package),
          abonent_actor(Ip, NewInputSpeedList, OutputSpeedList);
        true ->
          lager:info("ERROR!!!!!!!! ~n", []),
          abonent_actor(Ip, InputSpeedList, OutputSpeedList)
      end;
    {send_speed, HttpPid} ->
      MaxInput = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, InputSpeedList),
      MaxOutput = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, OutputSpeedList),
      HttpPid ! {abonent_speed, Ip, MaxInput, MaxOutput},
      abonent_actor(Ip, InputSpeedList, OutputSpeedList);
    Unknown ->
      lager:info("ERROR in abonent_actor! ~p~n", [Unknown]),
      abonent_actor(Ip, InputSpeedList, OutputSpeedList)
  end.

add_speed(SpeedList, Package) ->
  FirstTime = Package#nfrec_v5.first div 1000,
  LastTime = Package#nfrec_v5.last div 1000,

  AvgTraff = Package#nfrec_v5.d_octets * 8.0 / 1000.0 / ((LastTime - FirstTime )+ 1.0),
  NewSpeedList = update_or_append_counters(SpeedList, AvgTraff, LastTime, (LastTime - FirstTime) + 1),
  NewSpeedList2 = clear_old_counters(NewSpeedList),
  NewSpeedList2.


update_or_append_counters(SpeedList, _, _, Count) when Count =< 0 ->
  SpeedList;

update_or_append_counters(SpeedList, AvgTraff, From, Count) when Count > 300 ->
  lager:info("Big aggregation! ~p ~n", [Count]),
  update_or_append_counters(SpeedList, AvgTraff, From + (Count - 300), 300);

update_or_append_counters(SpeedList, AvgTraff, From, Count) ->
  NewSpeedList = orddict:update_counter(From, AvgTraff, SpeedList),
  update_or_append_counters(NewSpeedList, AvgTraff, From+1, Count-1).

clear_old_counters(SpeedList) ->
  MaxTime = orddict:fold(fun(Key, Value, AccIn) -> lists:max([Key, AccIn]) end, 0, SpeedList),
  MinTime = orddict:fold(fun(Key, Value, AccIn) -> lists:min([Key, AccIn]) end, MaxTime, SpeedList),
  if
    MaxTime - MinTime > 300 ->
      NewSpeedList = orddict:erase(MinTime, SpeedList),
      clear_old_counters(NewSpeedList);
    true ->
      SpeedList
  end.
