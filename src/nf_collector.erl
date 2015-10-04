-module(nf_collector).

-export([start_actor/0]).

-include("netflow_v5.hrl").

start_actor() ->
    spawn(fun () -> start() end).

start() ->
  nf_package_recv:start_actor(self()),
  AbonIpDict = dict:new(),
  main_loop(AbonIpDict, {0, -1, 0}).


main_loop(AbonIpDict, LostState) ->
  receive
    {flow, FlowList, NewLostState} ->
      NewAbonIpDict = process_package(AbonIpDict, FlowList),
      main_loop(NewAbonIpDict,NewLostState);

    {get_abonents_speed, HttpPid} ->
      HttpPid ! {abonents_speed_count, dict:size(AbonIpDict)},
      dict:map(
        fun(_, [V]) ->
          V ! {send_speed, HttpPid} end,
        AbonIpDict),
      main_loop(AbonIpDict, LostState);

    {get_packages_lost_count, HttpPid} ->
      HttpPid ! {packages_lost_count, LostState},
      main_loop(AbonIpDict, LostState);

    Unknown ->
      lager:info("ERROR! ~p~n", [Unknown]),
      main_loop(AbonIpDict, LostState)
  end.

process_package(AbonIpDict, [FlowItem | FlowList]) ->
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
  process_package(AbonIpDict3, FlowList);

process_package(AbonIpDict, []) ->
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
      MaxInput = orddict:fold(fun(_, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, InputSpeedList),
      MaxOutput = orddict:fold(fun(_, Value, AccIn) -> lists:max([Value, AccIn]) end, 0.0, OutputSpeedList),
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
  MaxTime = orddict:fold(fun(Key, _, AccIn) -> lists:max([Key, AccIn]) end, 0, SpeedList),
  MinTime = orddict:fold(fun(Key, _, AccIn) -> lists:min([Key, AccIn]) end, MaxTime, SpeedList),
  if
    MaxTime - MinTime > 300 ->
      NewSpeedList = orddict:erase(MinTime, SpeedList),
      clear_old_counters(NewSpeedList);
    true ->
      SpeedList
  end.
