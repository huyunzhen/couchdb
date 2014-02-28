#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable

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

-include_lib("couch_upr/include/couch_upr.hrl").

test_set_name() -> <<"couch_test_couch_upr">>.
num_set_partitions() -> 4.
num_docs() -> 1000.


main(_) ->
    test_util:init_code_path(),

    etap:plan(18),
    case (catch test()) of
        ok ->
            etap:end_tests();
        Other ->
            etap:diag(io_lib:format("Test died abnormally: ~p", [Other])),
            etap:bail(Other)
    end,
    %init:stop(),
    %receive after infinity -> ok end,
    ok.


test() ->
    couch_set_view_test_util:start_server(test_set_name()),
    setup_test(),
    % Populate failover log
    FailoverLogs = lists:map(fun(PartId) ->
        FailoverLog = [
            {10001, PartId + 3}, {10002, PartId + 2}, {10003, 0}],
        couch_upr_fake_server:set_failover_log(PartId, FailoverLog),
        FailoverLog
    end, lists:seq(0, num_set_partitions() - 1)),

    TestFun = fun(Item, Acc) ->
        case Item of
        snapshot_marker ->
            Acc;
        _ ->
            [Item|Acc]
        end
    end,

    {ok, Pid} = couch_upr:start(test_set_name(), test_set_name()),

    % Get the latest partition version first
    {ok, InitialFailoverLog0} = couch_upr:get_failover_log(Pid, 0),
    etap:is(InitialFailoverLog0, hd(FailoverLogs), "Failover log is correct"),

    % First parameter is the partition, the second is the sequence number
    % to start at.
    {ok, Docs1, FailoverLog1} = couch_upr:enum_docs_since(
        Pid, 0, InitialFailoverLog0, 4, 10, TestFun, []),
    etap:is(length(Docs1), 6, "Correct number of docs (6) in partition 0"),
    etap:is(FailoverLog1, lists:nth(1, FailoverLogs),
        "Failoverlog from partition 0 is correct"),

    {ok, InitialFailoverLog1} = couch_upr:get_failover_log(Pid, 1),
    {ok, Docs2, FailoverLog2} = couch_upr:enum_docs_since(
        Pid, 1, InitialFailoverLog1, 46, 165, TestFun, []),
    etap:is(length(Docs2), 119, "Correct number of docs (109) partition 1"),
    etap:is(FailoverLog2, lists:nth(2, FailoverLogs),
        "Failoverlog from partition 1 is correct"),

    {ok, InitialFailoverLog2} = couch_upr:get_failover_log(Pid, 2),
    {ok, Docs3, FailoverLog3} = couch_upr:enum_docs_since(
        Pid, 2, InitialFailoverLog2, 80, num_docs() div num_set_partitions(),
        TestFun, []),
    Expected3 = (num_docs() div num_set_partitions()) - 80,
    etap:is(length(Docs3), Expected3,
        io_lib:format("Correct number of docs (~p) partition 2", [Expected3])),
    etap:is(FailoverLog3, lists:nth(3, FailoverLogs),
        "Failoverlog from partition 2 is correct"),

    {ok, InitialFailoverLog3} = couch_upr:get_failover_log(Pid, 3),
    {ok, Docs4, FailoverLog4} = couch_upr:enum_docs_since(
        Pid, 3, InitialFailoverLog3, 0, 5, TestFun, []),
    etap:is(length(Docs4), 5, "Correct number of docs (5) partition 3"),
    etap:is(FailoverLog4, lists:nth(4, FailoverLogs),
        "Failoverlog from partition 3 is correct"),

    % Try a too high sequence number to get a erange error response
    {error, ErangeError} = couch_upr:enum_docs_since(
        Pid, 0, InitialFailoverLog0, 400, 450, TestFun, []),
    etap:is(ErangeError, wrong_start_sequence_number,
        "Correct error message for too high sequence number"),
    % Start sequence is bigger than end sequence
    {error, ErangeError2} = couch_upr:enum_docs_since(
        Pid, 0, InitialFailoverLog0, 5, 2, TestFun, []),
    etap:is(ErangeError2, wrong_start_sequence_number,
        "Correct error message for start sequence > end sequence"),


    Error = couch_upr:enum_docs_since(
        Pid, 1, [{4455667788, 1243}], 46, 165, TestFun, []),
    etap:is(Error, {rollback, 0},
        "Correct error for wrong failover log"),

    {ok, Seq0} = couch_upr:get_sequence_number(Pid, 0),
    etap:is(Seq0, num_docs() div num_set_partitions(),
        "Sequence number of partition 0 is correct"),
    {ok, Seq1} = couch_upr:get_sequence_number(Pid, 1),
    etap:is(Seq1, num_docs() div num_set_partitions(),
        "Sequence number of partition 1 is correct"),
    {ok, Seq2} = couch_upr:get_sequence_number(Pid, 2),
    etap:is(Seq2, num_docs() div num_set_partitions(),
         "Sequence number of partition 2 is correct"),
    {ok, Seq3} = couch_upr:get_sequence_number(Pid, 3),
    etap:is(Seq3, num_docs() div num_set_partitions(),
        "Sequence number of partition 3 is correct"),
    SeqError = couch_upr:get_sequence_number(Pid, 100000),
    etap:is(SeqError, {error, not_my_vbucket},
        "Too high partition number returns correct error"),

    % Test with too large failover log

    TooLargeFailoverLog = [{I, I} ||
        I <- lists:seq(0, ?UPR_MAX_FAILOVER_LOG_SIZE)],
    PartId = 1,
    couch_upr_fake_server:set_failover_log(PartId, TooLargeFailoverLog),
    etap:throws_ok(
      fun() -> couch_upr:enum_docs_since(
          Pid, PartId, [{0, 0}], 0, 100, TestFun, []) end,
      {error, <<"Failover log contains too many entries">>},
      "Throw exception when failover contains too many items"),

    couch_set_view_test_util:stop_server(),
    ok.

setup_test() ->
    couch_set_view_test_util:delete_set_dbs(test_set_name(), num_set_partitions()),
    couch_set_view_test_util:create_set_dbs(test_set_name(), num_set_partitions()),
    populate_set().


doc_id(I) ->
    iolist_to_binary(io_lib:format("doc_~8..0b", [I])).

create_docs(From, To) ->
    lists:map(
        fun(I) ->
            Cas = I,
            ExpireTime = 0,
            Flags = 0,
            RevMeta1 = <<Cas:64/native, ExpireTime:32/native, Flags:32/native>>,
            RevMeta2 = [[io_lib:format("~2.16.0b",[X]) || <<X:8>> <= RevMeta1 ]],
            RevMeta3 = iolist_to_binary(RevMeta2),
            {[
              {<<"meta">>, {[
                             {<<"id">>, doc_id(I)},
                             {<<"rev">>, <<"1-", RevMeta3/binary>>}
                            ]}},
              {<<"json">>, {[{<<"value">>, I}]}}
            ]}
        end,
        lists:seq(From, To)).

populate_set() ->
    etap:diag("Populating the " ++ integer_to_list(num_set_partitions()) ++
        " databases with " ++ integer_to_list(num_docs()) ++ " documents"),
    DocList = create_docs(1, num_docs()),
    ok = couch_set_view_test_util:populate_set_sequentially(
        test_set_name(),
        lists:seq(0, num_set_partitions() - 1),
        DocList).
