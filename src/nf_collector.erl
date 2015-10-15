-module(nf_collector).
-behaviour(gen_server).

-export([start_link/0]).
-export([send_flow_list/2, abonents_speed_request/1, get_packages_lost_count/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-include("netflow_v5.hrl").

-record(pkg_lost_state, {count, last_flow_seq, reiceve_count}).
-record(state, {abon_ip_dict, pkg_lost_state, flow_receiver_pid}).


start_link() ->
    gen_server:start_link({local, nf_collector}, ?MODULE, [], []).

init(_) ->
    FlowReceiverPid = nf_package_recv:start_actor(self()),
    AbonIpDict = dict:new(),
    PkgLostState = {0, -1, 0},
    {ok, #state(abon_ip_dict=AbonIpDict, pkg_lost_state=PkgLostState, flow_receiver_pid=FlowReceiverPid)}.

%% API

send_flow_list(FlowList, NewLostState) ->
    gen_server:cast(?MODULE, {flow, FlowList, NewLostState}).

%% придет 1 {abonents_speed_count, кол-во} и по каждому {abonent_speed, Ip, AvgInput, AvgOutput}
abonents_speed_request(Pid) ->
    gen_server:cast(?MODULE, {get_abonents_speed, Pid}).

get_packages_lost_state() ->
    gen_server:call(?MODULE, get_packages_lost_count).

%% OTP

handle_cast({flow, FlowList, NewLostState}, State) ->
    NewAbonIpDict = process_package(State#state.abon_ip_dict, FlowList),
    {noreply, State#state{abon_ip_dict=NewAbonIpDict, pkg_lost_state=NewLostState}}.

handle_cast({get_abonents_speed, Pid}, State) ->
    Pid ! {abonents_speed_count, dict:size(State#state.abon_ip_dict)},
    dict:map(
        fun(_, [V]) ->
              V ! {send_speed, Pid} end,
        State#state.abon_ip_dict),
    {noreply, State}.

handle_call(get_packages_lost_state, From, State) ->
    {reply, State#state.pkg_lost_state, State}.

handle_info(Msg, State) ->
    lager:info("?MODULE handle unknown message ~p~n", [Msg]),
    {noreply, State}.

%% other

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
      case orddict:size(InputSpeedList) of
        0 ->
          AvgInput = 0.0;
        _ ->
           AvgInput = orddict:fold(fun(_, Value, AccIn) -> Value + AccIn end, 0.0, InputSpeedList) / float(orddict:size(InputSpeedList))
      end,
      case orddict:size(OutputSpeedList) of
        0 ->
            AvgOutput = 0.0;
        _ ->
            AvgOutput = orddict:fold(fun(_, Value, AccIn) -> Value + AccIn end, 0.0, OutputSpeedList) / float(orddict:size(OutputSpeedList))
      end,
      HttpPid ! {abonent_speed, Ip, AvgInput, AvgOutput},
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
