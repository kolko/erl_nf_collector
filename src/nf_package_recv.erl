-module(nf_package_recv).

-export([start_actor/1]).

-include("netflow_v5.hrl").

start_actor(NfCollectorPid) ->
  {ok, SocketOptions} = make_sock_options(),
  {ok, Socket} = open_socket(SocketOptions),
  spawn(fun () -> package_recv(NfCollectorPid, Socket, LostState={0, -1, 0}) end).

open_socket({StrIP, Port, SocketOpts}) ->
  case gen_udp:open(Port, SocketOpts) of
    {ok, Socket} ->
      lager:info("Starting netflow service on ~s:~p~n", [StrIP, Port]),
      {ok, Socket};
    {error, Reason} ->
      {stop, Reason}
  end.

make_sock_options() ->
  StrIP = "0.0.0.0",
  Port = 9996,
  {ok, IP} = inet_parse:address(StrIP),
  Family = inet,
  SocketOpts = [binary, Family, {ip, IP}, {active, false}, {reuseaddr, true}, {buffer, 512000}],
  {ok, {StrIP, Port, SocketOpts}}.

package_recv(MainPid, Socket, LostState) ->
    case gen_udp:recv(Socket, 0) of
        {error, Reason} ->
            lager:info("Package recv got error! ~p~n", [Reason]),
            NewLostState = LostState;
        {ok, {Address, Port, Packet}} ->
            {ok, {Header, FlowList}} = parse_package(Packet, Address),
            NewLostState = calc_lost(LostState, Header),
            MainPid ! {flow, FlowList, NewLostState}
    end,
    package_recv(MainPid, Socket, NewLostState).

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