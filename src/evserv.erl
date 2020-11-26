-module(evserv).
-compile(export_all).

-record(state, {events, clients}).
-record(event, {name="",
                description="",
                pid,
                clientName,
                timeout={{1970,1,1}, {0,0,0}}}).

loop(S = #state{}) ->
    receive
        %% add client
        {Pid, MsgRef, {subscribe, Client, ClientName}} ->
            NewClients = orddict:store(ClientName, Client, S#state.clients),
            Pid ! {MsgRef, ok},
            loop(S#state{clients=NewClients});
        %% send event
        {Pid, MsgRef, {add, Name, Description, TimeOut, ClientName}} ->
            case valid_datetime(TimeOut) of
                true ->
                    EventPid = event:start_link(Name, TimeOut),
                    NewEvents = orddict:store(Name,
                                            #event{name=Name,
                                                    description=Description,
                                                    pid=EventPid,
                                                    clientName=ClientName,
                                                    timeout=TimeOut},
                                            S#state.events),
                    Pid ! {MsgRef, ok},
                    loop(S#state{events=NewEvents});
                false ->
                    Pid ! {MsgRef, {error, bad_timeout}},
                    loop(S)
            end;
        %% cancel alarm
        {Pid, MsgRef, {cancel, Name}} ->
            Events = case orddict:find(Name, S#state.events) of
                {ok, E} ->
                    event:cancel(E#event.pid),
                    orddict:erase(Name, S#state.events);
                error ->
                    S#state.events
                end,
            Pid ! {MsgRef, ok},
            loop(S#state{events=Events});
        %% execute alarm
        {done, Name} ->
            case orddict:find(Name, S#state.events) of
                {ok, E} ->
                    send_to_one_client({done, E#event.name, E#event.description, E#event.clientName},
                        S#state.clients, E#event.clientName),
                    % send_to_clients({done, E#event.name, E#event.description, E#event.clientName},
                    %     S#state.clients),
                    NewEvents = orddict:erase(Name, S#state.events),
                    loop(S#state{events=NewEvents});
                error ->
                    loop(S)
            end;
        shutdown ->
            exit(shutdown);
        {'DOWN', Ref, process, _Pid, _Reason} ->
            loop(S#state{clients=orddict:erase(Ref, S#state.clients)});
        code_change ->
            ?MODULE:loop(S);
        Unknown ->
            io:format("Unknown message: ~p~n",[Unknown]),
            loop(S)
    end.


init() ->
    loop(#state{events=orddict:new(),
                clients=orddict:new()}).

start() ->
    register(?MODULE, Pid=spawn(?MODULE, init, [])),
    Pid.

start_link() ->
    register(?MODULE, Pid=spawn_link(?MODULE, init, [])),
    Pid.

terminate() ->
    ?MODULE ! shutdown.

subscribe(Pid, ClientName) ->
    Ref = erlang:monitor(process, whereis(?MODULE)),
    ?MODULE ! {self(), Ref, {subscribe, Pid, ClientName}},
    receive
        {Ref, ok} ->
            {ok, Ref};
        {ClientRef, ok} ->
            {ok, ClientRef};
        {'DOWN', Ref, process, _Pid, Reason} ->
            {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

add_event(Name, Description, TimeOut, ClientRef) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {add, Name, Description, TimeOut, ClientRef}},
    receive
        {Ref, Msg} -> Msg
    after 5000 ->
        {error, timeout}
    end.

cancel(Name) ->
    Ref = make_ref(),
    ?MODULE ! {self(), Ref, {cancel, Name}},
    receive
        {Ref, ok} -> ok
    after 5000 ->
        {error, timeout}
    end.

listen(Delay) ->
    receive
        M = {done, _Name, _Description, _ClientName} ->
            [M | listen(0)]
    after Delay*1000 ->
        []
    end.

send_to_one_client(Msg, ClientDict, ClientName) ->
    case orddict:find(ClientName, ClientDict) of
        {ok, ClientPid} ->
            ClientPid ! Msg;
        error ->
            io:format("Not found: ~p~n",[ClientName])
    end.

send_to_clients({done, Name, Description, ClientN}, ClientDict) ->
    orddict:map(fun(_Name, Pid) -> Pid ! {done, Name, Description, _Name} end, ClientDict).

valid_datetime({Date, Time}) ->
    try
        calendar:valid_date(Date) andalso valid_time(Time)
    catch
        error:function_clause ->
            false
    end;

valid_datetime(_) ->
    false.

valid_time({H, M, S}) -> valid_time(H, M, S).
valid_time(H, M, S) when H >=0, H < 24,
                        M >= 0, M < 60,
                        S >= 0, S < 60 -> true;
valid_time(_,_,_) -> false.
