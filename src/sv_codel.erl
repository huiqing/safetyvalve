%%% @doc This is a loose translation of the following link from ACM:
%%% http://queue.acm.org/appendices/codel.html
%%% The document you want to read is
%%% "Controlling queue Delay" Kathleen Nichols, Van Jacobson, http://queue.acm.org/detail.cfm?id=2209336
%%% @end
-module(sv_codel).

-export([init/2, enqueue/3, dequeue/2]).

%% Scrutiny
-export([qstate/1]).

-record(state,
    { queue = queue:new(),
      dropping = false,
      drop_next = 0,
      interval = 100, % ms
      target = 5, %ms
      first_above_time = 0,
      count = 0
    }).

qstate(#state {
	queue = Q,
	dropping = Drop,
	drop_next = DN,
	interval = I,
	target = T,
	first_above_time = FAT,
	count = C
	}) ->
    [{queue, Q},
     {dropping, Drop},
     {drop_next, DN},
     {interval, I},
     {target, T},
     {first_above_time, FAT},
     {count, C}].

init(Target, Interval) -> #state{ target = Target, interval = Interval }.

enqueue(Pkt, TS, #state { queue = Q } = State) ->
  State#state { queue = queue:in({Pkt, TS}, Q) }.


control_law(T, I, C) ->
  T + I / math:sqrt(C).

dodequeue(Now, #state {
	queue = Q,
	target = Target,
	first_above_time = FirstAbove,
	interval = Interval } = State) ->
  case queue:out(Q) of
    {empty, NQ} ->
      {nodrop, empty, State#state { first_above_time = 0, queue = NQ }};
    {{value, {Pkt, InT}}, NQ} ->
      case Now - InT of
        Sojourn when Sojourn < Target ->
          {nodrop, Pkt, State#state { first_above_time = 0, queue = NQ }};
        _Sojourn when FirstAbove == 0 ->
          {nodrop, Pkt, State#state { first_above_time = Now + Interval, queue = NQ}};
        _Sojourn when Now >= FirstAbove ->
          {drop, Pkt, State#state { queue = NQ }};
        _Sojourn -> {nodrop, Pkt, State#state{ queue = NQ}}
      end
  end.

dequeue(Now, #state { dropping = Dropping } = State) ->
  case dodequeue(Now, State) of
    {nodrop, empty, NState} ->
      {empty, [], NState#state { dropping = false }};
    {nodrop, Pkt, #state {} = NState} when Dropping ->
      {ok, Pkt, [], NState#state { dropping = false }};
    {drop, Pkt, #state { drop_next = DropNext } = NState} when Now >= DropNext ->
      dequeue_drop_next(Now, Pkt, NState, []);
    {nodrop, Pkt, NState} when not Dropping ->
      {ok, Pkt, [], NState};
    {drop, Pkt, #state { drop_next = DN, interval = I, first_above_time = FirstAbove } = NState}
    	when not Dropping, Now - DN < I orelse Now - FirstAbove >= I ->
        		dequeue_start_drop(Now, NState, [Pkt]);
    {drop, Pkt, NState} when not Dropping ->
      {ok, Pkt, [], NState}
  end.

     

dequeue_drop_next(Now, Candidate, #state { drop_next = DN, dropping = true, count = C } = State, Dropped) ->
    case dodequeue(Now, State#state { count = C+1 }) of
      {nodrop, Res, NState} ->
        {ok, Res, [Candidate | Dropped], NState#state { dropping = false }};
      {drop, Res, #state { count = NC, interval = I } = NState} ->
        dequeue_drop_next(Now, Res, NState#state { drop_next = control_law(DN, I, NC) }, [Candidate | Dropped])
    end;
dequeue_drop_next(_Now, Candidate, #state { dropping = false } = State, Dropped) ->
  {ok, Candidate, Dropped, State}.

dequeue_start_drop(Now, #state { drop_next = DN, interval = Interval, count = Count } = State, Dropped)
	when Now - DN < Interval ->
    {ok, Dropped, 
    State#state {
    	dropping = true,
    	count = case Count > 2 of true -> Count - 2; false -> 1 end,
    	drop_next = control_law(Now, Interval, Count) }};
dequeue_start_drop(Now, #state { interval = Interval, count = Count } = State, Dropped) ->
    {ok, Dropped, State#state { dropping = true, count = 1, drop_next = control_law(Now, Interval, Count) }}.
