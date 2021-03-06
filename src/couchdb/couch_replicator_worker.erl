% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_replicator_worker).
-behaviour(gen_server).

% public API
-export([start_link/5]).

% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-include("couch_db.hrl").
-include("couch_api_wrap.hrl").
-include("couch_replicator.hrl").

% TODO: maybe make both buffer max sizes configurable
-define(DOC_BUFFER_BYTE_SIZE, 512 * 1024).   % for remote targets
-define(DOC_BUFFER_LEN, 10).                 % for local targets, # of documents
-define(MAX_BULK_ATT_SIZE, 64 * 1024).
-define(MAX_BULK_ATTS_PER_DOC, 8).
-define(STATS_DELAY, 10000000).              % 10 seconds (in microseconds)

-define(inc_stat(StatPos, Stats, Inc),
    setelement(StatPos, Stats, element(StatPos, Stats) + Inc)).

-import(couch_replicator_utils, [
    open_db/1,
    close_db/1,
    start_db_compaction_notifier/2,
    stop_db_compaction_notifier/1
]).
-import(couch_util, [
    to_binary/1,
    get_value/2,
    get_value/3
]).


-record(batch, {
    docs = [],
    size = 0
}).

-record(state, {
    cp,
    loop,
    max_parallel_conns,
    source,
    target,
    readers = [],
    writer = nil,
    pending_fetch = nil,
    flush_waiter = nil,
    stats = #rep_stats{},
    source_db_compaction_notifier = nil,
    target_db_compaction_notifier = nil,
    batch = #batch{}
}).



start_link(Cp, #db{} = Source, Target, ChangesManager, _MaxConns) ->
    Pid = spawn_link(fun() ->
        erlang:put(last_stats_report, os:timestamp()),
        queue_fetch_loop(Source, Target, Cp, Cp, ChangesManager)
    end),
    {ok, Pid};

start_link(Cp, Source, Target, ChangesManager, MaxConns) ->
    gen_server:start_link(
        ?MODULE, {Cp, Source, Target, ChangesManager, MaxConns}, []).


init({Cp, Source, Target, ChangesManager, MaxConns}) ->
    process_flag(trap_exit, true),
    Parent = self(),
    LoopPid = spawn_link(fun() ->
        queue_fetch_loop(Source, Target, Parent, Cp, ChangesManager)
    end),
    erlang:put(last_stats_report, os:timestamp()),
    State = #state{
        cp = Cp,
        max_parallel_conns = MaxConns,
        loop = LoopPid,
        source = open_db(Source),
        target = open_db(Target),
        source_db_compaction_notifier =
            start_db_compaction_notifier(Source, self()),
        target_db_compaction_notifier =
            start_db_compaction_notifier(Target, self())
    },
    {ok, State}.


handle_call({fetch_doc, {_Id, _Rev} = Params}, {Pid, _} = From,
    #state{loop = Pid, readers = Readers, pending_fetch = nil,
        source = Src, target = Tgt, max_parallel_conns = MaxConns} = State) ->
    case length(Readers) of
    Size when Size < MaxConns ->
        Reader = spawn_doc_reader(Src, Tgt, Params),
        NewState = State#state{
            readers = [Reader | Readers]
        },
        {reply, ok, NewState};
    _ ->
        NewState = State#state{
            pending_fetch = {From, Params}
        },
        {noreply, NewState}
    end;

handle_call({batch_doc, Doc}, From, State) ->
    gen_server:reply(From, ok),
    {noreply, maybe_flush_docs(Doc, State)};

handle_call({add_stats, IncStats}, From, #state{stats = Stats} = State) ->
    gen_server:reply(From, ok),
    NewStats = couch_replicator_utils:sum_stats(Stats, IncStats),
    NewStats2 = maybe_report_stats(State#state.cp, NewStats),
    {noreply, State#state{stats = NewStats2}};

handle_call(flush, {Pid, _} = From,
    #state{loop = Pid, writer = nil, flush_waiter = nil,
        target = Target, batch = Batch} = State) ->
    State2 = case State#state.readers of
    [] ->
        State#state{writer = spawn_writer(Target, Batch)};
    _ ->
        State
    end,
    {noreply, State2#state{flush_waiter = From}}.


handle_cast({db_compacted, DbName},
    #state{source = #db{name = DbName} = Source} = State) ->
    {ok, NewSource} = couch_db:reopen(Source),
    {noreply, State#state{source = NewSource}};

handle_cast({db_compacted, DbName},
    #state{target = #db{name = DbName} = Target} = State) ->
    {ok, NewTarget} = couch_db:reopen(Target),
    {noreply, State#state{target = NewTarget}};

handle_cast(Msg, State) ->
    {stop, {unexpected_async_call, Msg}, State}.


handle_info({'EXIT', Pid, normal}, #state{loop = Pid} = State) ->
    #state{
        batch = #batch{docs = []}, readers = [], writer = nil,
        pending_fetch = nil, flush_waiter = nil
    } = State,
    {stop, normal, State};

handle_info({'EXIT', Pid, normal}, #state{writer = Pid} = State) ->
    {noreply, after_full_flush(State)};

handle_info({'EXIT', Pid, normal}, #state{writer = nil} = State) ->
    #state{
        readers = Readers, writer = Writer, batch = Batch,
        source = Source, target = Target,
        pending_fetch = Fetch, flush_waiter = FlushWaiter
    } = State,
    case Readers -- [Pid] of
    Readers ->
        {noreply, State};
    Readers2 ->
        State2 = case Fetch of
        nil ->
            case (FlushWaiter =/= nil) andalso (Writer =:= nil) andalso
                (Readers2 =:= [])  of
            true ->
                State#state{
                    readers = Readers2,
                    writer = spawn_writer(Target, Batch)
                };
            false ->
                State#state{readers = Readers2}
            end;
        {From, FetchParams} ->
            Reader = spawn_doc_reader(Source, Target, FetchParams),
            gen_server:reply(From, ok),
            State#state{
                readers = [Reader | Readers2],
                pending_fetch = nil
            }
        end,
        {noreply, State2}
    end;

handle_info({'EXIT', Pid, Reason}, State) ->
   {stop, {process_died, Pid, Reason}, State}.


terminate(_Reason, State) ->
    close_db(State#state.source),
    close_db(State#state.target),
    stop_db_compaction_notifier(State#state.source_db_compaction_notifier),
    stop_db_compaction_notifier(State#state.target_db_compaction_notifier).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


queue_fetch_loop(Source, Target, Parent, Cp, ChangesManager) ->
    ChangesManager ! {get_changes, self()},
    receive
    {closed, ChangesManager} ->
        ok;
    {changes, ChangesManager, Changes, ReportSeq} ->
        Target2 = open_db(Target),
        {IdRevs, Stats0} = find_missing(Changes, Target2),
        case Source of
        #db{} ->
            Source2 = open_db(Source),
            Stats = local_process_batch(
                IdRevs, Cp, Source2, Target2, #batch{}, Stats0),
            close_db(Source2);
        #httpdb{} ->
            ok = gen_server:call(Parent, {add_stats, Stats0}, infinity),
            remote_process_batch(IdRevs, Parent),
            {ok, Stats} = gen_server:call(Parent, flush, infinity)
        end,
        close_db(Target2),
        ok = gen_server:call(Cp, {report_seq_done, ReportSeq, Stats}, infinity),
        erlang:put(last_stats_report, os:timestamp()),
        ?LOG_DEBUG("Worker reported completion of seq ~p", [ReportSeq]),
        queue_fetch_loop(Source, Target, Parent, Cp, ChangesManager)
    end.


local_process_batch([], _Cp, _Src, _Tgt, #batch{docs = []}, Stats) ->
    Stats;

local_process_batch([], Cp, Source, Target, #batch{docs = Docs, size = Size}, Stats) ->
    case Target of
    #httpdb{} ->
        ?LOG_DEBUG("Worker flushing doc batch of size ~p bytes", [Size]);
    #db{} ->
        ?LOG_DEBUG("Worker flushing doc batch of ~p docs", [Size])
    end,
    Stats2 = flush_docs(Target, Docs),
    Stats3 = couch_replicator_utils:sum_stats(Stats, Stats2),
    local_process_batch([], Cp, Source, Target, #batch{}, Stats3);

local_process_batch([IdRevs | Rest], Cp, Source, Target, Batch, Stats) ->
    {ok, {_, DocList, Stats2, _}} = fetch_doc(
        Source, IdRevs, fun local_doc_handler/2, {Target, [], Stats, Cp}),
    {Batch2, Stats3} = lists:foldl(
        fun(Doc, {Batch0, Stats0}) ->
            {Batch1, S} = maybe_flush_docs(Target, Batch0, Doc),
            {Batch1, couch_replicator_utils:sum_stats(Stats0, S)}
        end,
        {Batch, Stats2}, DocList),
    local_process_batch(Rest, Cp, Source, Target, Batch2, Stats3).


remote_process_batch([], _Parent) ->
    ok;

remote_process_batch([{Id, Rev} | Rest], Parent) ->
    ok = gen_server:call(Parent, {fetch_doc, {Id, Rev}}, infinity),
    remote_process_batch(Rest, Parent).


spawn_doc_reader(Source, Target, FetchParams) ->
    Parent = self(),
    spawn_link(fun() ->
        Source2 = open_db(Source),
        fetch_doc(
            Source2, FetchParams, fun remote_doc_handler/2, {Parent, Target}),
        close_db(Source2)
    end).


fetch_doc(Source, {Id, _Rev}, DocHandler, Acc) ->
    couch_api_wrap:open_doc(
            Source, Id, [deleted], DocHandler, Acc).


local_doc_handler({ok, Doc}, {Target, DocList, Stats, Cp}) ->
    Stats2 = ?inc_stat(#rep_stats.docs_read, Stats, 1),
    {ok, {Target, [Doc | DocList], Stats2, Cp}};
local_doc_handler(_, Acc) ->
    {ok, Acc}.


remote_doc_handler({ok, Doc}, {Parent, _} = Acc) ->
    ok = gen_server:call(Parent, {batch_doc, Doc}, infinity),
    {ok, Acc};
remote_doc_handler(_, Acc) ->
    {ok, Acc}.


spawn_writer(Target, #batch{docs = DocList, size = Size}) ->
    case {Target, Size > 0} of
    {#httpdb{}, true} ->
        ?LOG_DEBUG("Worker flushing doc batch of size ~p bytes", [Size]);
    {#db{}, true} ->
        ?LOG_DEBUG("Worker flushing doc batch of ~p docs", [Size]);
    _ ->
        ok
    end,
    Parent = self(),
    spawn_link(
        fun() ->
            Target2 = open_db(Target),
            Stats = flush_docs(Target2, DocList),
            close_db(Target2),
            ok = gen_server:call(Parent, {add_stats, Stats}, infinity)
        end).


after_full_flush(#state{stats = Stats, flush_waiter = Waiter} = State) ->
    gen_server:reply(Waiter, {ok, Stats}),
    erlang:put(last_stats_report, os:timestamp()),
    State#state{
        stats = #rep_stats{},
        flush_waiter = nil,
        writer = nil,
        batch = #batch{}
    }.


maybe_flush_docs(Doc,State) ->
    #state{
        target = Target, batch = Batch,
        stats = Stats, cp = Cp
    } = State,
    {Batch2, WStats} = maybe_flush_docs(Target, Batch, Doc),
    Stats2 = couch_replicator_utils:sum_stats(Stats, WStats),
    Stats3 = ?inc_stat(#rep_stats.docs_read, Stats2, 1),
    Stats4 = maybe_report_stats(Cp, Stats3),
    State#state{stats = Stats4, batch = Batch2}.


maybe_flush_docs(#httpdb{} = Target, Batch, Doc) ->
    #batch{docs = DocAcc, size = SizeAcc} = Batch,
    JsonDoc = couch_doc:to_json_bin(Doc),
    case SizeAcc + iolist_size(JsonDoc) of
    SizeAcc2 when SizeAcc2 > ?DOC_BUFFER_BYTE_SIZE ->
        ?LOG_DEBUG("Worker flushing doc batch of size ~p bytes", [SizeAcc2]),
        Stats = flush_docs(Target, [JsonDoc | DocAcc]),
        {#batch{}, Stats};
    SizeAcc2 ->
        {#batch{docs = [JsonDoc | DocAcc], size = SizeAcc2}, #rep_stats{}}
    end;

maybe_flush_docs(#db{} = Target, #batch{docs = DocAcc, size = SizeAcc}, Doc) ->
    case SizeAcc + 1 of
    SizeAcc2 when SizeAcc2 >= ?DOC_BUFFER_LEN ->
        ?LOG_DEBUG("Worker flushing doc batch of ~p docs", [SizeAcc2]),
        Stats = flush_docs(Target, [Doc | DocAcc]),
        {#batch{}, Stats};
    SizeAcc2 ->
        {#batch{docs = [Doc | DocAcc], size = SizeAcc2}, #rep_stats{}}
    end.



flush_docs(_Target, []) ->
    #rep_stats{};

flush_docs(Target, DocList) ->
    case couch_api_wrap:update_docs(Target, DocList, [delay_commit],
                                    replicated_changes) of
        ok ->
            #rep_stats{docs_written = length(DocList)};
        {ok, {Props}} ->
            DbUri = couch_api_wrap:db_uri(Target),
            ?LOG_ERROR("Replicator: couldn't write document `~s`, revision `~s`,"
                " to target database `~s`. Error: `~s`, reason: `~s`.",
                [get_value(id, Props, ""), get_value(rev, Props, ""), DbUri,
                    get_value(error, Props, ""), get_value(reason, Props, "")]),
            #rep_stats{
                docs_written = 0, doc_write_failures = length(DocList)
            }
    end.


find_missing(DocInfos, Target) ->
    {IdRevs, AllRevsCount} = lists:foldr(
        fun(#doc_info{id = Id, rev = Rev}, {IdRevAcc, CountAcc}) ->
            {[{Id, Rev} | IdRevAcc], CountAcc + 1}
        end,
        {[], 0}, DocInfos),
    {ok, Missing} = couch_api_wrap:get_missing_revs(Target, IdRevs),
    MissingRevsCount = length(Missing),
    Stats = #rep_stats{
        missing_checked = AllRevsCount,
        missing_found = MissingRevsCount
    },
    {Missing, Stats}.


maybe_report_stats(Cp, Stats) ->
    Now = os:timestamp(),
    case timer:now_diff(erlang:get(last_stats_report), Now) >= ?STATS_DELAY of
    true ->
        ok = gen_server:call(Cp, {add_stats, Stats}, infinity),
        erlang:put(last_stats_report, Now),
        #rep_stats{};
    false ->
        Stats
    end.
